//
//  RMMapSingleTiledLayerView.m
//  Geo Bucket
//
//  Created by Matti Mustonen on 8/19/12.
//  Copyright (c) 2012 Matti Mustonen. All rights reserved.
//

#import "RMMapSingleTiledLayerView.h"

#import "RMMapView.h"
#import "RMTileSource.h"
#import "RMTileImage.h"
#import "RMTileCache.h"
#import "RMMBTilesSource.h"
#import "RMDBMapSource.h"
#import "RMAbstractWebMapSource.h"
#import "RMDatabaseCache.h"

#define IS_VALID_TILE_IMAGE(image) (image != nil && [image isKindOfClass:[UIImage class]] && ![[RMTileImage errorTile] isEqual:tileImage])

@implementation RMMapSingleTiledLayerView
{
    RMMapView *_mapView;
    NSArray* _tileSources;
}

@synthesize useSnapshotRenderer = _useSnapshotRenderer;

+ (Class)layerClass
{
    return [CATiledLayer class];
}

- (CATiledLayer *)tiledLayer
{
    return (CATiledLayer *)self.layer;
}

- (id)initWithFrame:(CGRect)frame mapView:(RMMapView *)aMapView forTileSources:(NSArray*) aTileSources
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    
    self.opaque = NO;
    
    _mapView = aMapView;
    _tileSources = aTileSources;
    self.useSnapshotRenderer = NO;
    
    CATiledLayer *tiledLayer = [self tiledLayer];
    size_t levelsOf2xMagnification = _mapView.tileSourcesMaxZoom;
    if (_mapView.adjustTilesForRetinaDisplay && _mapView.screenScale > 1.0) levelsOf2xMagnification += 1;
    tiledLayer.levelsOfDetail = levelsOf2xMagnification;
    tiledLayer.levelsOfDetailBias = levelsOf2xMagnification;
    
    return self;
}

- (void)dealloc
{
    self.layer.contents = nil;
    _mapView = nil;
}

- (void)didMoveToWindow
{
    self.contentScaleFactor = 1.0f;
}

- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    CGRect rect   = CGContextGetClipBoundingBox(context);
    CGRect bounds = self.bounds;
    short zoom    = log2(bounds.size.width / rect.size.width);
    
    NSLog(@"drawLayer: {{%f,%f},{%f,%f}}", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    if (self.useSnapshotRenderer)
    {
        zoom = (short)ceilf(_mapView.adjustedZoomForRetinaDisplay);
        CGFloat rectSize = bounds.size.width / powf(2.0, (float)zoom);
        
        int x1 = floor(rect.origin.x / rectSize),
        x2 = floor((rect.origin.x + rect.size.width) / rectSize),
        y1 = floor(fabs(rect.origin.y / rectSize)),
        y2 = floor(fabs((rect.origin.y + rect.size.height) / rectSize));
        
        //        NSLog(@"Tiles from x1:%d, y1:%d to x2:%d, y2:%d @ zoom %d", x1, y1, x2, y2, zoom);
        
        
        UIGraphicsPushContext(context);
        
        for (int x=x1; x<=x2; ++x)
        {
            for (int y=y1; y<=y2; ++y)
            {
                for (id <RMTileSource> _tileSource in _tileSources) {
                    UIImage *tileImage = [_tileSource imageForTile:RMTileMake(x, y, zoom) inCache:[_mapView tileCache]];
                    
                    if (IS_VALID_TILE_IMAGE(tileImage)){
                        [tileImage drawInRect:CGRectMake(x * rectSize, y * rectSize, rectSize, rectSize)];
                        break;
                    }
                }
                
            }
        }
        
        UIGraphicsPopContext();
        
    }
    else
    {
        int x = floor(rect.origin.x / rect.size.width),
        y = floor(fabs(rect.origin.y / rect.size.height));
        
        if (_mapView.adjustTilesForRetinaDisplay && _mapView.screenScale > 1.0)
        {
            zoom--;
            x >>= 1;
            y >>= 1;
        }
        
        //        NSLog(@"Tile @ x:%d, y:%d, zoom:%d", x, y, zoom);
        
        UIGraphicsPushContext(context);
        
        UIImage *tileImage = nil;
        
        for (id <RMTileSource> _tileSource in _mapView.tileSourcesContainer.tileSources) {
            
            if ([_tileSource isKindOfClass:[RMMBTilesSource class]]){
                
                if ((zoom >= [_tileSource minZoom]) && (zoom <= [_tileSource maxZoom])) {
                    tileImage = [(RMMBTilesSource*) _tileSource imageForTile:RMTileMake(x, y, zoom) inCache:nil];
                    if (!IS_VALID_TILE_IMAGE(tileImage)) {
                        tileImage = nil;
                    }
                    else{
                        break;
                    }
                }
                
                
            }
        }
        
        if (!tileImage){
            for (id <RMTileSource> _tileSource in _mapView.tileSourcesContainer.tileSources) {
                
                // for non-local tiles, consult cache directly first (if possible)
                //
                if (_tileSource.isCacheable)
                    tileImage = [[_mapView tileCache] cachedImage:RMTileMake(x, y, zoom) withCacheKey:[_tileSource uniqueTilecacheKey]];
                
                if ( ! tileImage && [_tileSource isKindOfClass:[RMAbstractWebMapSource class]])
                {
                    // fire off an asynchronous retrieval
                    //
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void)
                                   {
                                       // ensure only one request for a URL at a time
                                       //
                                       @synchronized ([(RMAbstractWebMapSource *)_tileSource URLForTile:RMTileMake(x, y, zoom)])
                                       {
                                           // this will return quicker if cached since above attempt, else block on fetch
                                           //
                                           id image = [_tileSource imageForTile:RMTileMake(x, y, zoom) inCache:[_mapView tileCache]];
                                           if (_tileSource.isCacheable && image && IS_VALID_TILE_IMAGE(image))
                                           {
                                               dispatch_async(dispatch_get_main_queue(), ^(void)
                                                              {
                                                                  // do it all again for this tile, next time synchronously from cache
                                                                  //
                                                                  [self.layer setNeedsDisplayInRect:rect];
                                                              });
                                           }
                                       }
                                   });
                }
                
                if (tileImage) {
                    break;
                }
                
            }}
        
        if ( ! tileImage)
        {
            if (_mapView.missingTilesDepth == 0)
            {
                tileImage = [RMTileImage errorTile];
            }
            else
            {
                
                for (id <RMTileSource> _tileSource in _tileSources) {
                    // tries to return lower zoom level tiles if a tile cannot be found
                    tileImage = [self getImage:_tileSource withZoom:zoom x:x y:y];
                }
            }
        }
        
        if (IS_VALID_TILE_IMAGE(tileImage))
        {
            if (_mapView.adjustTilesForRetinaDisplay && _mapView.screenScale > 1.0)
            {
                // Crop the image
                float xCrop = (floor(rect.origin.x / rect.size.width) / 2.0) - x;
                float yCrop = (floor(rect.origin.y / rect.size.height) / 2.0) - y;
                
                CGRect cropBounds = CGRectMake(tileImage.size.width * xCrop,
                                               tileImage.size.height * yCrop,
                                               tileImage.size.width * 0.5,
                                               tileImage.size.height * 0.5);
                
                CGImageRef imageRef = CGImageCreateWithImageInRect([tileImage CGImage], cropBounds);
                tileImage = [UIImage imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
            }
            
            if (_mapView.debugTiles)
            {
                UIGraphicsBeginImageContext(tileImage.size);
                
                CGContextRef debugContext = UIGraphicsGetCurrentContext();
                
                CGRect debugRect = CGRectMake(0, 0, tileImage.size.width, tileImage.size.height);
                
                [tileImage drawInRect:debugRect];
                
                UIFont *font = [UIFont systemFontOfSize:32.0];
                
                CGContextSetStrokeColorWithColor(debugContext, [UIColor whiteColor].CGColor);
                CGContextSetLineWidth(debugContext, 2.0);
                CGContextSetShadowWithColor(debugContext, CGSizeMake(0.0, 0.0), 5.0, [UIColor blackColor].CGColor);
                
                CGContextStrokeRect(debugContext, debugRect);
                
                CGContextSetFillColorWithColor(debugContext, [UIColor whiteColor].CGColor);
                
                NSString *debugString = [NSString stringWithFormat:@"Zoom %d", zoom];
                CGSize debugSize1 = [debugString sizeWithFont:font];
                [debugString drawInRect:CGRectMake(5.0, 5.0, debugSize1.width, debugSize1.height) withFont:font];
                
                debugString = [NSString stringWithFormat:@"(%d, %d)", x, y];
                CGSize debugSize2 = [debugString sizeWithFont:font];
                [debugString drawInRect:CGRectMake(5.0, 5.0 + debugSize1.height + 5.0, debugSize2.width, debugSize2.height) withFont:font];
                
                tileImage = UIGraphicsGetImageFromCurrentImageContext();
                
                UIGraphicsEndImageContext();
            }
            
            [tileImage drawInRect:rect];
        }
        else
        {
            //            NSLog(@"Invalid image for {%d,%d} @ %d", x, y, zoom);
        }
        
        UIGraphicsPopContext();
    }
}

-(UIImage*)getImage:(id <RMTileSource>) _tileSource withZoom:(NSUInteger) zoom x:(NSUInteger) x y:(NSUInteger) y{
    NSUInteger currentTileDepth = 1, currentZoom = zoom - currentTileDepth;
    UIImage* tileImage = nil;
    while ( currentZoom >= _tileSource.minZoom && currentZoom <= _tileSource.maxZoom && currentTileDepth <= _mapView.missingTilesDepth)
    {
        float nextX = x / powf(2.0, (float)currentTileDepth),
        nextY = y / powf(2.0, (float)currentTileDepth);
        float nextTileX = floor(nextX),
        nextTileY = floor(nextY);
        
        tileImage = [_tileSource imageForTile:RMTileMake((int)nextTileX, (int)nextTileY, currentZoom) inCache:[_mapView tileCache]];
        
        if (IS_VALID_TILE_IMAGE(tileImage))
        {
            // crop
            float cropSize = 1.0 / powf(2.0, (float)currentTileDepth);
            
            CGRect cropBounds = CGRectMake(tileImage.size.width * (nextX - nextTileX),
                                           tileImage.size.height * (nextY - nextTileY),
                                           tileImage.size.width * cropSize,
                                           tileImage.size.height * cropSize);
            
            CGImageRef imageRef = CGImageCreateWithImageInRect([tileImage CGImage], cropBounds);
            tileImage = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
            return tileImage;
            
        }
        else
        {
            tileImage = nil;
        }
        
        currentTileDepth++;
        currentZoom = zoom - currentTileDepth;
    }
    return tileImage;
}

@end
