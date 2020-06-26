//
//  RMUserTrackingBarButtonItem.m
//  MapView
//
// Copyright (c) 2008-2013, Route-Me Contributors
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

#import "RMUserTrackingBarButtonItem.h"

#import "RMMapView.h"
#import "RMUserLocation.h"

typedef enum : NSUInteger {
    RMUserTrackingButtonStateNone     = 0,
    RMUserTrackingButtonStateActivity = 1,
    RMUserTrackingButtonStateLocation = 2,
    RMUserTrackingButtonStateHeading  = 3
} RMUserTrackingButtonState;

@interface RMMapView (PrivateMethods)

@property (nonatomic, weak) RMUserTrackingBarButtonItem *userTrackingBarButtonItem;

@end

#pragma mark -

@interface RMUserTrackingBarButtonItem ()

@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UIImageView *buttonImageView;
@property (nonatomic, strong) UIActivityIndicatorView *activityView;
@property (nonatomic, assign) RMUserTrackingButtonState state;
@property (nonatomic, assign) UIViewTintAdjustmentMode tintAdjustmentMode;

- (void)createBarButtonItem;
- (void)updateState;
- (void)changeMode:(id)sender;

@end

#pragma mark -

@implementation RMUserTrackingBarButtonItem

- (id)initWithMapView:(RMMapView *)mapView
{
    if ( ! (self = [super initWithCustomView:[[UIControl alloc] initWithFrame:CGRectMake(0, 0, 32, 32)]]))
        return nil;

    [self createBarButtonItem];
    [self setMapView:mapView];

    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if ( ! (self = [super initWithCoder:aDecoder]))
        return nil;

    [self setCustomView:[[UIControl alloc] initWithFrame:CGRectMake(0, 0, 32, 32)]];

    [self createBarButtonItem];

    return self;
}

- (void)createBarButtonItem
{
    self.buttonImageView = [[UIImageView alloc] initWithImage:nil];
    self.buttonImageView.contentMode = UIViewContentModeCenter;
    self.buttonImageView.frame = CGRectMake(0, 0, 32, 32);
    self.buttonImageView.center = self.customView.center;
    self.buttonImageView.userInteractionEnabled = NO;

    [self updateImage];

    [self.customView addSubview:self.buttonImageView];

    self.activityView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.activityView.hidesWhenStopped = YES;
    self.activityView.center = self.customView.center;
    self.activityView.userInteractionEnabled = NO;

    [self.customView addSubview:self.activityView];

    [((UIControl *)self.customView) addTarget:self action:@selector(changeMode:) forControlEvents:UIControlEventTouchUpInside];

    self.state = RMUserTrackingButtonStateNone;

    [self updateSize:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSize:) name:UIApplicationWillChangeStatusBarOrientationNotification object:nil];
}

- (void)dealloc
{
    [self.mapView removeObserver:self forKeyPath:@"userTrackingMode"];
    [self.mapView removeObserver:self forKeyPath:@"userLocation.location"];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillChangeStatusBarOrientationNotification object:nil];
}

#pragma mark -

- (void)setMapView:(RMMapView *)newMapView
{
    if ( ! [newMapView isEqual:self.mapView])
    {
        [self.mapView removeObserver:self forKeyPath:@"userTrackingMode"];
        [self.mapView removeObserver:self forKeyPath:@"userLocation.location"];

        self.mapView = newMapView;
        [self.mapView addObserver:self forKeyPath:@"userTrackingMode"      options:NSKeyValueObservingOptionNew context:nil];
        [self.mapView addObserver:self forKeyPath:@"userLocation.location" options:NSKeyValueObservingOptionNew context:nil];

        self.mapView.userTrackingBarButtonItem = self;

        [self updateState];
    }
}

- (void)setTintColor:(UIColor *)newTintColor
{
    [super setTintColor:newTintColor];

    if (RMPreVersion7)
        self.segmentedControl.tintColor = newTintColor;
    else
        [self updateImage];
}

#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    [self updateState];
}

#pragma mark -

- (void)updateSize:(NSNotification *)notification
{
    NSInteger orientation = (notification ? [[notification.userInfo objectForKey:UIApplicationStatusBarOrientationUserInfoKey] integerValue] : [[UIApplication sharedApplication] statusBarOrientation]);

    CGFloat dimension = (UIInterfaceOrientationIsPortrait(orientation) ? (RMPostVersion7 ? 36 : 32) : 24);

    self.customView.bounds = self.buttonImageView.bounds = self.segmentedControl.bounds = CGRectMake(0, 0, dimension, dimension);
    [self.segmentedControl setWidth:dimension forSegmentAtIndex:0];
    self.width = dimension;

    self.segmentedControl.center = self.buttonImageView.center = self.activityView.center = CGPointMake(dimension / 2, dimension / 2 - (RMPostVersion7 ? 1 : 0));

    [self updateImage];
}

- (void)updateImage
{
    if (RMPreVersion7)
    {
        if (self.mapView.userTrackingMode == RMUserTrackingModeFollowWithHeading)
            self.buttonImageView.image = [RMMapView resourceImageNamed:@"TrackingHeading.png"];
        else
            self.buttonImageView.image = [RMMapView resourceImageNamed:@"TrackingLocation.png"];
    }
    else
    {
        CGRect rect = CGRectMake(0, 0, self.customView.bounds.size.width, self.customView.bounds.size.height);

        UIGraphicsBeginImageContextWithOptions(rect.size, NO, [[UIScreen mainScreen] scale]);

        CGContextRef context = UIGraphicsGetCurrentContext();

        UIImage *image;

        if (self.mapView.userTrackingMode == RMUserTrackingModeNone || ! self.mapView)
            image = [RMMapView resourceImageNamed:@"TrackingLocationOffMask.png"];
        else if (self.mapView.userTrackingMode == RMUserTrackingModeFollow)
            image = [RMMapView resourceImageNamed:@"TrackingLocationMask.png"];
        else if (self.mapView.userTrackingMode == RMUserTrackingModeFollowWithHeading)
            image = [RMMapView resourceImageNamed:@"TrackingHeadingMask.png"];

        UIGraphicsPushContext(context);
        [image drawAtPoint:CGPointMake((rect.size.width  - image.size.width) / 2, ((rect.size.height - image.size.height) / 2) + 2)];
        UIGraphicsPopContext();

        CGContextSetBlendMode(context, kCGBlendModeSourceIn);
        CGContextSetFillColorWithColor(context, self.tintColor.CGColor);
        CGContextFillRect(context, rect);

        self.buttonImageView.image = UIGraphicsGetImageFromCurrentImageContext();

        UIGraphicsEndImageContext();

        CABasicAnimation *backgroundColorAnimation = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
        CABasicAnimation *cornerRadiusAnimation    = [CABasicAnimation animationWithKeyPath:@"cornerRadius"];

        backgroundColorAnimation.duration = cornerRadiusAnimation.duration = 0.25;

        CGColorRef filledColor = [[self.tintColor colorWithAlphaComponent:0.1] CGColor];
        CGColorRef clearColor  = [[UIColor clearColor] CGColor];

        CGFloat onRadius  = 4.0;
        CGFloat offRadius = 0;

        if (self.mapView.userTrackingMode != RMUserTrackingModeNone && self.customView.layer.cornerRadius != onRadius)
        {
            backgroundColorAnimation.fromValue = (__bridge id)clearColor;
            backgroundColorAnimation.toValue   = (__bridge id)filledColor;

            cornerRadiusAnimation.fromValue = @(offRadius);
            cornerRadiusAnimation.toValue   = @(onRadius);

            self.customView.layer.backgroundColor = filledColor;
            self.customView.layer.cornerRadius    = onRadius;
        }
        else if (self.mapView.userTrackingMode == RMUserTrackingModeNone && self.customView.layer.cornerRadius != offRadius)
        {
            backgroundColorAnimation.fromValue = (__bridge id)filledColor;
            backgroundColorAnimation.toValue   = (__bridge id)clearColor;

            cornerRadiusAnimation.fromValue = @(onRadius);
            cornerRadiusAnimation.toValue   = @(offRadius);

            self.customView.layer.backgroundColor = clearColor;
            self.customView.layer.cornerRadius    = offRadius;
        }

        [self.customView.layer addAnimation:backgroundColorAnimation forKey:@"animateBackgroundColor"];
        [self.customView.layer addAnimation:cornerRadiusAnimation    forKey:@"animateCornerRadius"];
    }
}

- (void)updateState
{
    // "selection" state
    //
    if (RMPreVersion7)
        self.segmentedControl.selectedSegmentIndex = (self.mapView.userTrackingMode == RMUserTrackingModeNone ? UISegmentedControlNoSegment : 0);

    // activity/image state
    //
    if (self.mapView.userTrackingMode != RMUserTrackingModeNone && ( ! self.mapView.userLocation || ! self.mapView.userLocation.location || (self.mapView.userLocation.location.coordinate.latitude == 0 && self.mapView.userLocation.location.coordinate.longitude == 0)))
    {
        // if we should be tracking but don't yet have a location, show activity
        //
        @weakify(self);
        [UIView animateWithDuration:0.25
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^(void)
                         {
            @strongify(self);
                             self.buttonImageView.transform = CGAffineTransformMakeScale(0.01, 0.01);
                             self.activityView.transform    = CGAffineTransformMakeScale(0.01, 0.01);
                         }
                         completion:^(BOOL finished)
                         {
            @strongify(self);
                             self.buttonImageView.hidden = YES;

                             [self.activityView startAnimating];

                             [UIView animateWithDuration:0.25 animations:^(void)
                             {
                                 @strongify(self);
                                 self.buttonImageView.transform = CGAffineTransformIdentity;
                                 self.activityView.transform    = CGAffineTransformIdentity;
                             }];
                         }];

        self.state = RMUserTrackingButtonStateActivity;
    }
    else
    {
        if ((self.mapView.userTrackingMode == RMUserTrackingModeNone              && self.state != RMUserTrackingButtonStateNone)     ||
            (self.mapView.userTrackingMode == RMUserTrackingModeFollow            && self.state != RMUserTrackingButtonStateLocation) ||
            (self.mapView.userTrackingMode == RMUserTrackingModeFollowWithHeading && self.state != RMUserTrackingButtonStateHeading))
        {
            // we'll always animate if leaving activity state
            //
            __block BOOL animate = (self.state == RMUserTrackingButtonStateActivity);
            @weakify(self);
            [UIView animateWithDuration:0.25
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^(void)
                             {
                @strongify(self);
                                 if (self.state == RMUserTrackingButtonStateHeading &&
                                     self.mapView.userTrackingMode != RMUserTrackingModeFollowWithHeading)
                                 {
                                     // coming out of heading mode
                                     //
                                     animate = YES;
                                 }
                                 else if ((self.state != RMUserTrackingButtonStateHeading) &&
                                          self.mapView.userTrackingMode == RMUserTrackingModeFollowWithHeading)
                                 {
                                     // going into heading mode
                                     //
                                     animate = YES;
                                 }

                                 if (animate)
                                     self.buttonImageView.transform = CGAffineTransformMakeScale(0.01, 0.01);

                                 if (self.state == RMUserTrackingButtonStateActivity)
                                     self.activityView.transform = CGAffineTransformMakeScale(0.01, 0.01);
                             }
                             completion:^(BOOL finished)
                             {
                @strongify(self);
                                 [self updateImage];

                                 self.buttonImageView.hidden = NO;

                                 if (self.state == RMUserTrackingButtonStateActivity)
                                     [self.activityView stopAnimating];

                                 [UIView animateWithDuration:0.25 animations:^(void)
                                 {
                                     @strongify(self);
                                     if (animate)
                                         self.buttonImageView.transform = CGAffineTransformIdentity;

                                     if (self.state == RMUserTrackingButtonStateActivity)
                                         self.activityView.transform = CGAffineTransformIdentity;
                                 }];
                             }];

            if (self.mapView.userTrackingMode == RMUserTrackingModeNone)
                self.state = RMUserTrackingButtonStateNone;
            else if (self.mapView.userTrackingMode == RMUserTrackingModeFollow)
                self.state = RMUserTrackingButtonStateLocation;
            else if (self.mapView.userTrackingMode == RMUserTrackingModeFollowWithHeading)
                self.state = RMUserTrackingButtonStateHeading;
        }
    }
}

- (void)changeMode:(id)sender
{
    if (self.mapView)
    {
        switch (self.mapView.userTrackingMode)
        {
            case RMUserTrackingModeNone:
            default:
            {
                self.mapView.userTrackingMode = RMUserTrackingModeFollow;
                
                break;
            }
            case RMUserTrackingModeFollow:
            {
                if ([CLLocationManager headingAvailable])
                    self.mapView.userTrackingMode = RMUserTrackingModeFollowWithHeading;
                else
                    self.mapView.userTrackingMode = RMUserTrackingModeNone;

                break;
            }
            case RMUserTrackingModeFollowWithHeading:
            {
                self.mapView.userTrackingMode = RMUserTrackingModeNone;

                break;
            }
        }
    }

    [self updateState];
}

@end
