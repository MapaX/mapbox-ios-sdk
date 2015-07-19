//
//  RMMapSingleTiledLayerView.h
//  Geo Bucket
//
//  Created by Matti Mustonen on 8/19/12.
//  Copyright (c) 2012 Matti Mustonen. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "RMTileSource.h"
#import "RMMapTiledLayerView.h"

@class RMMapView;

@interface RMMapSingleTiledLayerView : UIView

@property (nonatomic, assign) BOOL useSnapshotRenderer;
@property (nonatomic, readonly) NSArray* tileSources;

- (id)initWithFrame:(CGRect)frame mapView:(RMMapView *)aMapView forTileSources:(NSArray*) aTileSources;

@end
