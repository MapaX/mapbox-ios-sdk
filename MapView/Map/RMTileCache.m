//
//  RMTileCache.m
//
// Copyright (c) 2008-2009, Route-Me Contributors
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this
//   list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import <sys/utsname.h>

#import "RMTileCache.h"
#import "RMMemoryCache.h"
#import "RMDatabaseCache.h"

#import "RMConfiguration.h"
#import "RMTileSource.h"

#import "RMAbstractWebMapSource.h"

#import "RMTileCacheDownloadOperation.h"

@interface RMTileCache (Configuration)

- (id <RMTileCache>)memoryCacheWithConfig:(NSDictionary *)cfg;
- (id <RMTileCache>)databaseCacheWithConfig:(NSDictionary *)cfg;

@property(nonatomic) NSMutableArray *privateTileCaches;

@end

@implementation RMTileCache
{


    // The memory cache, if we have one
    // This one has its own variable because we want to propagate cache hits down in
    // the cache hierarchy up to the memory cache
    RMMemoryCache *_memoryCache;
    NSTimeInterval _expiryPeriod;

    dispatch_queue_t _tileCacheQueue;
    
    id <RMTileSource>_activeTileSource;
    NSOperationQueue *_backgroundFetchQueue;
}

@synthesize backgroundCacheDelegate;

- (id)initWithExpiryPeriod:(NSTimeInterval)period
{
    if (!(self = [super init]))
        return nil;

    self.privateTileCaches = [NSMutableArray new];
    _tileCacheQueue = dispatch_queue_create("routeme.tileCacheQueue", DISPATCH_QUEUE_CONCURRENT);

    _memoryCache = nil;
    _expiryPeriod = period;
    
    self.backgroundCacheDelegate = nil;
    _activeTileSource = nil;
    _backgroundFetchQueue = nil;

    id cacheCfg = [[RMConfiguration sharedInstance] cacheConfiguration];
    if (!cacheCfg)
        cacheCfg = [NSArray arrayWithObjects:
                    [NSDictionary dictionaryWithObject: @"memory-cache" forKey: @"type"],
                    [NSDictionary dictionaryWithObject: @"db-cache"     forKey: @"type"],
                    nil];

    for (id cfg in cacheCfg)
    {
        id <RMTileCache> newCache = nil;

        @try {

            NSString *type = [cfg valueForKey:@"type"];

            if ([@"memory-cache" isEqualToString:type])
            {
                _memoryCache = [self memoryCacheWithConfig:cfg];
                continue;
            }

            if ([@"db-cache" isEqualToString:type])
                newCache = [self databaseCacheWithConfig:cfg];

            if (newCache)
                [self.privateTileCaches addObject:newCache];
            else
                RMLog(@"failed to create cache of type %@", type);

        }
        @catch (NSException * e) {
            RMLog(@"*** configuration error: %@", [e reason]);
        }
    }

    return self;
}

- (id)init
{
    if (!(self = [self initWithExpiryPeriod:0]))
        return nil;

    return self;
}

- (void)dealloc
{
    if (self.isBackgroundCaching)
        [self cancelBackgroundCache];
    @weakify(self);
    @weakify(_memoryCache);
    dispatch_barrier_sync(_tileCacheQueue, ^{
        @strongify(self);
        @strongify(_memoryCache);
         _memoryCache = nil;
         self.privateTileCaches = nil;
    });
    
#if ! OS_OBJECT_USE_OBJC
    dispatch_release(_tileCacheQueue);
#endif
}

- (void)addCache:(id <RMTileCache>)cache
{
    @weakify(self);
    dispatch_barrier_async(_tileCacheQueue, ^{
        @strongify(self);
        [self.privateTileCaches addObject:cache];
    });
}

- (void)insertCache:(id <RMTileCache>)cache atIndex:(NSUInteger)index
{
    @weakify(self);
    dispatch_barrier_async(_tileCacheQueue, ^{
        @strongify(self);
        if (index >= [self.privateTileCaches count])
            [self.privateTileCaches addObject:cache];
        else
            [self.privateTileCaches insertObject:cache atIndex:index];
    });
}

- (NSArray *)tileCaches
{
    return [NSArray arrayWithArray:self.privateTileCaches];
}

+ (NSNumber *)tileHash:(RMTile)tile
{
	return [NSNumber numberWithUnsignedLongLong:RMTileKey(tile)];
}

- (UIImage *)cachedImage:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
    return [self cachedImage:tile withCacheKey:aCacheKey bypassingMemoryCache:NO];
}

- (UIImage *)cachedImage:(RMTile)tile withCacheKey:(NSString *)aCacheKey bypassingMemoryCache:(BOOL)shouldBypassMemoryCache
{
    __block UIImage *image = nil;

    if (!shouldBypassMemoryCache)
        image = [_memoryCache cachedImage:tile withCacheKey:aCacheKey];

    if (image)
        return image;
    @weakify(_memoryCache);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(_memoryCache);
        for (id <RMTileCache> cache in self.privateTileCaches)
        {
            image = [cache cachedImage:tile withCacheKey:aCacheKey];

            if (image != nil && !shouldBypassMemoryCache)
            {
                [_memoryCache addImage:image forTile:tile withCacheKey:aCacheKey];
                break;
            }
        }

    });

    return image;
}

- (void)addImage:(UIImage *)image forTile:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
    if (!image || !aCacheKey)
        return;

    [_memoryCache addImage:image forTile:tile withCacheKey:aCacheKey];
    @weakify(self);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(self);
        for (id <RMTileCache> cache in self.privateTileCaches)
        {	
            if ([cache respondsToSelector:@selector(addImage:forTile:withCacheKey:)])
                [cache addImage:image forTile:tile withCacheKey:aCacheKey];
        }

    });
}

- (void)addDiskCachedImageData:(NSData *)data forTile:(RMTile)tile withCacheKey:(NSString *)aCacheKey
{
    if (!data || !aCacheKey)
        return;

    @weakify(self);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(self);
        for (id <RMTileCache> cache in self.privateTileCaches)
        {
            if ([cache respondsToSelector:@selector(addDiskCachedImageData:forTile:withCacheKey:)])
                [cache addDiskCachedImageData:data forTile:tile withCacheKey:aCacheKey];
        }

    });
}

- (void)didReceiveMemoryWarning
{
	LogMethod();

    [_memoryCache didReceiveMemoryWarning];

    @weakify(self);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(self);

        for (id<RMTileCache> cache in self.privateTileCaches)
        {
            [cache didReceiveMemoryWarning];
        }

    });
}

- (void)removeAllCachedImages
{
    [_memoryCache removeAllCachedImages];

    @weakify(self);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(self);

        for (id<RMTileCache> cache in self.privateTileCaches)
        {
            [cache removeAllCachedImages];
        }

    });
}

- (void)removeAllCachedImagesForCacheKey:(NSString *)cacheKey
{
    [_memoryCache removeAllCachedImagesForCacheKey:cacheKey];

    @weakify(self);
    dispatch_sync(_tileCacheQueue, ^{
        @strongify(self);

        for (id<RMTileCache> cache in self.privateTileCaches)
        {
            [cache removeAllCachedImagesForCacheKey:cacheKey];
        }
    });
}

- (BOOL)isBackgroundCaching
{
    return (_activeTileSource || _backgroundFetchQueue);
}

- (BOOL)markCachingComplete
{
    BOOL incomplete = (_activeTileSource || _backgroundFetchQueue);

    _activeTileSource = nil;
    _backgroundFetchQueue = nil;

    return incomplete;
}

- (NSUInteger)tileCountForSouthWest:(CLLocationCoordinate2D)southWest northEast:(CLLocationCoordinate2D)northEast minZoom:(NSUInteger)minZoom maxZoom:(NSUInteger)maxZoom
{
    NSUInteger minCacheZoom = minZoom;
    NSUInteger maxCacheZoom = maxZoom;

    CLLocationDegrees minCacheLat = southWest.latitude;
    CLLocationDegrees maxCacheLat = northEast.latitude;
    CLLocationDegrees minCacheLon = southWest.longitude;
    CLLocationDegrees maxCacheLon = northEast.longitude;

    NSAssert(minCacheZoom <= maxCacheZoom, @"Minimum zoom should be less than or equal to maximum zoom");
    NSAssert(maxCacheLat  >  minCacheLat,  @"Northernmost bounds should exceed southernmost bounds");
    NSAssert(maxCacheLon  >  minCacheLon,  @"Easternmost bounds should exceed westernmost bounds");

    NSUInteger n, xMin, yMax, xMax, yMin;

    NSUInteger totalTiles = 0;

    for (NSUInteger zoom = minCacheZoom; zoom <= maxCacheZoom; zoom++)
    {
        n = pow(2.0, zoom);
        xMin = floor(((minCacheLon + 180.0) / 360.0) * n);
        yMax = floor((1.0 - (logf(tanf(minCacheLat * M_PI / 180.0) + 1.0 / cosf(minCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);
        xMax = floor(((maxCacheLon + 180.0) / 360.0) * n);
        yMin = floor((1.0 - (logf(tanf(maxCacheLat * M_PI / 180.0) + 1.0 / cosf(maxCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);

        totalTiles += (xMax + 1 - xMin) * (yMax + 1 - yMin);
    }

    return totalTiles;
}

- (void)beginBackgroundCacheForTileSource:(id <RMTileSource>)tileSource southWest:(CLLocationCoordinate2D)southWest northEast:(CLLocationCoordinate2D)northEast minZoom:(NSUInteger)minZoom maxZoom:(NSUInteger)maxZoom
{
    if (self.isBackgroundCaching)
        return;

    NSAssert([tileSource isKindOfClass:[RMAbstractWebMapSource class]], @"only web-based tile sources are supported for downloading");

    _activeTileSource = tileSource;

    _backgroundFetchQueue = [NSOperationQueue new];
    [_backgroundFetchQueue setMaxConcurrentOperationCount:6];
    if ([_backgroundFetchQueue respondsToSelector:@selector(setQualityOfService:)])
    {
        [_backgroundFetchQueue setQualityOfService:NSQualityOfServiceUtility];
    }

    NSUInteger totalTiles = [self tileCountForSouthWest:southWest northEast:northEast minZoom:minZoom maxZoom:maxZoom];

    NSUInteger minCacheZoom = minZoom;
    NSUInteger maxCacheZoom = maxZoom;

    CLLocationDegrees minCacheLat = southWest.latitude;
    CLLocationDegrees maxCacheLat = northEast.latitude;
    CLLocationDegrees minCacheLon = southWest.longitude;
    CLLocationDegrees maxCacheLon = northEast.longitude;

    if ([self.backgroundCacheDelegate respondsToSelector:@selector(tileCache:didBeginBackgroundCacheWithCount:forTileSource:)])
    {
        [self.backgroundCacheDelegate tileCache:self
           didBeginBackgroundCacheWithCount:totalTiles
                              forTileSource:_activeTileSource];
    }

    NSUInteger n, xMin, yMax, xMax, yMin;

    __block NSUInteger progTile = 0;

    for (NSUInteger zoom = minCacheZoom; zoom <= maxCacheZoom; zoom++)
    {
        n = pow(2.0, zoom);
        xMin = floor(((minCacheLon + 180.0) / 360.0) * n);
        yMax = floor((1.0 - (logf(tanf(minCacheLat * M_PI / 180.0) + 1.0 / cosf(minCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);
        xMax = floor(((maxCacheLon + 180.0) / 360.0) * n);
        yMin = floor((1.0 - (logf(tanf(maxCacheLat * M_PI / 180.0) + 1.0 / cosf(maxCacheLat * M_PI / 180.0)) / M_PI)) / 2.0 * n);

        for (NSUInteger x = xMin; x <= xMax; x++)
        {
            for (NSUInteger y = yMin; y <= yMax; y++)
            {
                RMTileCacheDownloadOperation *operation = [[RMTileCacheDownloadOperation alloc] initWithTile:RMTileMake((uint32_t)x, (uint32_t)y, zoom)
                                                                                                forTileSource:_activeTileSource
                                                                                                   usingCache:self];

                __weak RMTileCacheDownloadOperation *internalOperation = operation;
                __weak RMTileCache *weakSelf = self;
                @weakify(self);
                [operation setCompletionBlock:^(void)
                {
                    @strongify(self);
                    if ( ! [internalOperation isCancelled])
                    {
                        progTile++;

                        if ([self.backgroundCacheDelegate respondsToSelector:@selector(tileCache:didBackgroundCacheTile:withIndex:ofTotalTileCount:)])
                        {
                            [self.backgroundCacheDelegate tileCache:weakSelf
                                         didBackgroundCacheTile:RMTileMake((uint32_t)x, (uint32_t)y, zoom)
                                                      withIndex:progTile
                                               ofTotalTileCount:totalTiles];
                        }

                        if (progTile == totalTiles)
                        {
                            dispatch_async(dispatch_get_main_queue(), ^(void)
                            {
                                [weakSelf markCachingComplete];

                                if ([self.backgroundCacheDelegate respondsToSelector:@selector(tileCacheDidFinishBackgroundCache:)])
                                {
                                    [self.backgroundCacheDelegate tileCacheDidFinishBackgroundCache:weakSelf];
                                }
                            });
                        }
                    }
                    else
                    {
                        if ([self.backgroundCacheDelegate respondsToSelector:@selector(tileCache:didReceiveError:whenCachingTile:)])
                        {
                            [self.backgroundCacheDelegate tileCache:weakSelf
                                                didReceiveError:internalOperation.error
                                                whenCachingTile:RMTileMake((uint32_t)x, (uint32_t)y, zoom)];
                        }
                    }
                }];

                [_backgroundFetchQueue addOperation:operation];
            }
        }
    }
}

- (void)cancelBackgroundCache
{
    __weak NSOperationQueue *weakBackgroundFetchQueue = _backgroundFetchQueue;
    __weak RMTileCache *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void)
    {
        dispatch_sync(dispatch_get_main_queue(), ^(void)
        {
            [weakBackgroundFetchQueue cancelAllOperations];
            [weakBackgroundFetchQueue waitUntilAllOperationsAreFinished];

            if ([weakSelf markCachingComplete])
            {
                if ([self.backgroundCacheDelegate respondsToSelector:@selector(tileCacheDidCancelBackgroundCache:)])
                {
                    [self.backgroundCacheDelegate tileCacheDidCancelBackgroundCache:weakSelf];
                }
            }
        });
    });
}

static NSMutableDictionary *predicateValues = nil;

- (NSDictionary *)predicateValues
{
    static dispatch_once_t predicateValuesOnceToken;

    dispatch_once(&predicateValuesOnceToken, ^{
        struct utsname systemInfo;
        uname(&systemInfo);

        NSString *machine = [NSString stringWithCString:systemInfo.machine encoding:NSASCIIStringEncoding];

        predicateValues = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                           [[UIDevice currentDevice] model], @"model",
                           machine, @"machine",
                           [[UIDevice currentDevice] systemName], @"systemName",
                           [NSNumber numberWithFloat:[[[UIDevice currentDevice] systemVersion] floatValue]], @"systemVersion",
                           [NSNumber numberWithInt: (int) [[UIDevice currentDevice] userInterfaceIdiom]], @"userInterfaceIdiom",
                           nil];

        if ( ! ([machine isEqualToString:@"i386"] || [machine isEqualToString:@"x86_64"]))
        {
            NSNumber *machineNumber = [NSNumber numberWithFloat:[[[machine stringByTrimmingCharactersInSet:[NSCharacterSet letterCharacterSet]] stringByReplacingOccurrencesOfString:@"," withString:@"."] floatValue]];

            if ( ! machineNumber)
                machineNumber = [NSNumber numberWithFloat:0.0];

            [predicateValues setObject:machineNumber forKey:@"machineNumber"];
        }
        else
        {
            [predicateValues setObject:[NSNumber numberWithFloat:0.0] forKey:@"machineNumber"];
        }

        // A predicate might be:
        // (self.model = 'iPad' and self.machineNumber >= 3) or (self.machine = 'x86_64')
        // See NSPredicate

//        NSLog(@"Predicate values:\n%@", [predicateValues description]);
    });

    return predicateValues;
}

- (id <RMTileCache>)memoryCacheWithConfig:(NSDictionary *)cfg
{
    NSUInteger capacity = 32;

	NSNumber *capacityNumber = [cfg objectForKey:@"capacity"];
	if (capacityNumber != nil)
        capacity = [capacityNumber unsignedIntegerValue];

    NSArray *predicates = [cfg objectForKey:@"predicates"];

    if (predicates)
    {
        NSDictionary *predicateValues = [self predicateValues];

        for (NSDictionary *predicateDescription in predicates)
        {
            NSString *predicate = [predicateDescription objectForKey:@"predicate"];
            if ( ! predicate)
                continue;

            if ( ! [[NSPredicate predicateWithFormat:predicate] evaluateWithObject:predicateValues])
                continue;

            capacityNumber = [predicateDescription objectForKey:@"capacity"];
            if (capacityNumber != nil)
                capacity = [capacityNumber unsignedIntegerValue];
        }
    }

	return [[RMMemoryCache alloc] initWithCapacity:capacity];
}

- (id <RMTileCache>)databaseCacheWithConfig:(NSDictionary *)cfg
{
    BOOL useCacheDir = NO;
    RMCachePurgeStrategy strategy = RMCachePurgeStrategyFIFO;

    NSUInteger capacity = 1000;
    NSUInteger minimalPurge = capacity / 10;

    // Defaults

    NSNumber *capacityNumber = [cfg objectForKey:@"capacity"];

    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad && [cfg objectForKey:@"capacity-ipad"])
    {
        NSLog(@"***** WARNING: deprecated config option capacity-ipad, use a predicate instead: -[%@ %@] (line %d)", self, NSStringFromSelector(_cmd), __LINE__);
        capacityNumber = [cfg objectForKey:@"capacity-ipad"];
    }

    NSString *strategyStr = [cfg objectForKey:@"strategy"];
    NSNumber *useCacheDirNumber = [cfg objectForKey:@"useCachesDirectory"];
    NSNumber *minimalPurgeNumber = [cfg objectForKey:@"minimalPurge"];
    NSNumber *expiryPeriodNumber = [cfg objectForKey:@"expiryPeriod"];

    NSArray *predicates = [cfg objectForKey:@"predicates"];

    if (predicates)
    {
        NSDictionary *predicateValues = [self predicateValues];

        for (NSDictionary *predicateDescription in predicates)
        {
            NSString *predicate = [predicateDescription objectForKey:@"predicate"];
            if ( ! predicate)
                continue;

            if ( ! [[NSPredicate predicateWithFormat:predicate] evaluateWithObject:predicateValues])
                continue;

            if ([predicateDescription objectForKey:@"capacity"])
                capacityNumber = [predicateDescription objectForKey:@"capacity"];
            if ([predicateDescription objectForKey:@"strategy"])
                strategyStr = [predicateDescription objectForKey:@"strategy"];
            if ([predicateDescription objectForKey:@"useCachesDirectory"])
                useCacheDirNumber = [predicateDescription objectForKey:@"useCachesDirectory"];
            if ([predicateDescription objectForKey:@"minimalPurge"])
                minimalPurgeNumber = [predicateDescription objectForKey:@"minimalPurge"];
            if ([predicateDescription objectForKey:@"expiryPeriod"])
                expiryPeriodNumber = [predicateDescription objectForKey:@"expiryPeriod"];
        }
    }

    // Check the values

    if ([[NSUserDefaults standardUserDefaults] integerForKey:@"RMTileCacheCapacity"] > 0) {
        capacityNumber = [NSNumber numberWithInteger:[[NSUserDefaults standardUserDefaults] integerForKey:@"RMTileCacheCapacity"]];
    }
    
    if (capacityNumber != nil)
    {
        NSInteger value = [capacityNumber intValue];

        // 0 is valid: it means no capacity limit
        if (value >= 0)
        {
            capacity =  value;
            minimalPurge = MAX(1,capacity / 10);
        }
        else
        {
            RMLog(@"illegal value for capacity: %ld", (long)value);
        }
    }

    if (strategyStr != nil)
    {
        if ([strategyStr caseInsensitiveCompare:@"FIFO"] == NSOrderedSame) strategy = RMCachePurgeStrategyFIFO;
        if ([strategyStr caseInsensitiveCompare:@"LRU"] == NSOrderedSame) strategy = RMCachePurgeStrategyLRU;
    }
    else
    {
        strategyStr = @"FIFO";
    }

    if (useCacheDirNumber != nil)
        useCacheDir = [useCacheDirNumber boolValue];

    if (minimalPurgeNumber != nil && capacity != 0)
    {
        NSUInteger value = [minimalPurgeNumber unsignedIntValue];

        if (value > 0 && value<=capacity)
            minimalPurge = value;
        else
            RMLog(@"minimalPurge must be at least one and at most the cache capacity");
    }

    if (expiryPeriodNumber != nil)
        _expiryPeriod = [expiryPeriodNumber doubleValue];

    RMDatabaseCache *dbCache = [[RMDatabaseCache alloc] initUsingCacheDir:useCacheDir];
    [dbCache setCapacity:capacity];
    [dbCache setPurgeStrategy:strategy];
    [dbCache setMinimalPurge:minimalPurge];
    [dbCache setExpiryPeriod:_expiryPeriod];

    return dbCache;
}

@end
