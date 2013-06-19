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

@implementation RMMapSingleTiledLayerView

@synthesize useSnapshotRenderer = _useSnapshotRenderer;
@synthesize mapView;

+ (Class)layerClass
{
    return [CATiledLayer class];
}

- (CATiledLayer *)tiledLayer
{
    return (CATiledLayer *)self.layer;
}

- (id)initWithFrame:(CGRect)frame mapView:(RMMapView *)aMapView forTileSources:(NSArray*)aTileSources
{
    if (!(self = [super initWithFrame:frame]))
        return nil;
    
    self.opaque = NO;
    
    self.mapView = aMapView;
    
    self.useSnapshotRenderer = NO;
    
    CATiledLayer *tiledLayer = [self tiledLayer];
    size_t levelsOf2xMagnification = mapView.tileSourcesContainer.maxZoom;
    if (mapView.adjustTilesForRetinaDisplay) levelsOf2xMagnification += 1;
    tiledLayer.levelsOfDetail = levelsOf2xMagnification;
    tiledLayer.levelsOfDetailBias = levelsOf2xMagnification;
    
    return self;
}

- (void)dealloc
{
    for (id<RMTileSource> tileSource in mapView.tileSourcesContainer.tileSources) {
        [tileSource cancelAllDownloads];
    }
    self.layer.contents = nil;
    self.mapView = nil;
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
    
    //    NSLog(@"drawLayer: {{%f,%f},{%f,%f}}", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    @autoreleasepool {
    if (self.useSnapshotRenderer)
    {
        zoom = (short)ceilf(mapView.adjustedZoomForRetinaDisplay);
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
                    for ( id<RMTileSource> tileSource in mapView.tileSourcesContainer.tileSources) {
                        UIImage *tileImage = [tileSource imageForTile:RMTileMake(x, y, zoom) inCache:[mapView tileCache]];
                        if (tileImage != nil && ![[RMTileImage errorTile] isEqual:tileImage]) {
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
        
        //        NSLog(@"Tile @ x:%d, y:%d, zoom:%d", x, y, zoom);
        
        UIGraphicsPushContext(context);
        
        UIImage *tileImage = nil;
        NSLog(@"Tile source count is %i", [mapView.tileSourcesContainer.tileSources count]);
        for ( id<RMTileSource> tileSource in mapView.tileSourcesContainer.tileSources) {
            RMLog(@"Getting map from the tilesource '%@' Zoom %d", [tileSource shortName], zoom);
            if (zoom >= tileSource.minZoom && zoom <= tileSource.maxZoom) {
                tileImage = [tileSource imageForTile:RMTileMake(x, y, zoom) inCache:[mapView tileCache]];
                if (tileImage != nil && ![[RMTileImage errorTile] isEqual:tileImage]) {
                    break;
                }
            }
        }
        
        if ( ! tileImage)
        {
            if (mapView.missingTilesDepth == 0)
            {
                tileImage = [RMTileImage errorTile];
            }
            else
            {
                float minZoom = 100;
                
                for (id<RMTileSource> tileSource in mapView.tileSourcesContainer.tileSources) {
                    if ([tileSource minZoom] < minZoom) {
                        minZoom = [tileSource minZoom];
                    }
                }
                NSUInteger currentTileDepth = 1, currentZoom = zoom - currentTileDepth;
                
                // tries to return lower zoom level tiles if a tile cannot be found
                while ( !tileImage && currentZoom >= minZoom && currentTileDepth <= mapView.missingTilesDepth)
                {
                    float nextX = x / powf(2.0, (float)currentTileDepth),
                    nextY = y / powf(2.0, (float)currentTileDepth);
                    float nextTileX = floor(nextX),
                    nextTileY = floor(nextY);
                    
                    for ( id<RMTileSource> tileSource in mapView.tileSourcesContainer.tileSources) {
                        if (currentZoom >= tileSource.minZoom && currentZoom <= tileSource.maxZoom) {
                        tileImage = [tileSource imageForTile:RMTileMake((int)nextTileX, (int)nextTileY, currentZoom) inCache:[mapView tileCache]];
                        if (tileImage != nil && ![[RMTileImage errorTile] isEqual:tileImage]) {
                            break;
                        }
                        }
                    }
                    
                    
                    if (tileImage)
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
                        
                        break;
                    }
                    
                    currentTileDepth++;
                    currentZoom = zoom - currentTileDepth;
                }
            }
        }
        
        if (mapView.debugTiles)
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
        
        
        
        UIGraphicsPopContext();
    }
    }
}

@end
