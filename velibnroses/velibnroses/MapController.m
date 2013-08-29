//
//  MapController.m
//  velibnroses
//
//  Created by Thomas on 04/07/13.
//  Copyright (c) 2013 OneLight Studio. All rights reserved.
//

#import "MapController.h"
#import <CoreLocation/CoreLocation.h>
#import "Constants.h"
#import "WSRequest.h"
#import "Station.h"
#import "GeoUtils.h"
#import "RoutePolyline.h"
#import "PlaceAnnotation.h"
#import "ImageUtils.h"

@interface MapController ()
    
@end

@implementation MapController {
    MKUserLocation *startUserLocation;
    WSRequest *_wsRequest;
    NSMutableArray *_stations;
    CLLocationCoordinate2D _northWestSpanCorner, _southEastSpanCorner;
    BOOL _isMapLoaded;
    BOOL _searching;
    CLLocation *_departureLocation;
    CLLocation *_arrivalLocation;
    NSTimer *_timer;
    RoutePolyline *_route;
    int _mapViewState;
    BOOL _isSearchViewVisible;
    NSMutableArray *_departureCloseStations;
    NSMutableArray *_arrivalCloseStations;
    Station *_departureStation;
    Station *_arrivalStation;
    int _jcdRequestAttemptsNumber;
}

@synthesize mapPanel;
@synthesize searchPanel;
@synthesize departureField;
@synthesize arrivalField;
@synthesize bikeField;
@synthesize standField;
@synthesize closeSearchPanelButton;
@synthesize searchBarButton;
@synthesize searchButton;

# pragma mark -

- (void)registerOn
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackgroundNotificationReceived:) name:NOTIFICATION_DID_ENTER_BACKGROUND object:nil];
    NSLog(@"register on %@", NOTIFICATION_DID_ENTER_BACKGROUND);
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForegroundNotificationReceived:) name:NOTIFICATION_WILL_ENTER_FOREGROUND object:nil];
    NSLog(@"register on %@", NOTIFICATION_WILL_ENTER_FOREGROUND);
}

- (void)initView
{
    self.mapPanel.delegate = self;
    self.mapPanel.showsUserLocation = YES;
    [self.mapPanel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapMap:)]];
    
    self.navigationItem.titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Images/NavigationBar/NBLogo"]];
    
    CGRect searchFrame = self.searchPanel.frame;
    searchFrame.origin.y = -searchFrame.size.height;
    self.searchPanel.frame = searchFrame;
    self.bikeField.text = @"1";
    self.standField.text = @"1";
    self.cancelBarButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Images/NavigationBar/NBClose"] style:UIBarButtonItemStyleBordered target:self action:@selector(cancelBarButtonClicked:)];
    
    _isMapLoaded = false;
    _mapViewState = MAP_VIEW_DEFAULT_STATE;
    _isSearchViewVisible = false;
    
    [self.searchBarButton setBackgroundImage:[UIImage new] forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [self.cancelBarButton setBackgroundImage:[UIImage new] forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    
    UIImage *buttonBg = [[UIImage imageNamed:@"Images/SearchPanel/SPButtonBg"]
                            resizableImageWithCapInsets:UIEdgeInsetsMake(16, 16, 16, 16)];
    [self.searchButton setBackgroundImage:buttonBg forState:UIControlStateNormal];
    
    _departureCloseStations = [[NSMutableArray alloc] init];
    _arrivalCloseStations = [[NSMutableArray alloc] init];
}

- (void) startTimer {
    if (_timer == nil)
    {
        NSLog(@"start timer");
        _timer = [NSTimer scheduledTimerWithTimeInterval:TIME_BEFORE_REFRESH_DATA_IN_SECONDS target:self selector:@selector(timerFired:) userInfo:nil repeats:YES];
    }
}

- (void) stopTimer {
    if (_timer != nil)
    {
        NSLog(@"stop timer");
        [_timer invalidate];
        _timer = nil;
    }
}

# pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self registerOn];
    [self initView];
    
    _jcdRequestAttemptsNumber = 0;
    NSLog(@"init jcd ws");
    _wsRequest = [[WSRequest alloc] initWithResource:JCD_WS_ENTRY_POINT_PARAM_VALUE inBackground:TRUE];
    [_wsRequest appendParameterWithKey:JCD_API_KEY_PARAM_NAME andValue:JCD_API_KEY_PARAM_VALUE];
    [_wsRequest handleResultWith:^(id json) {
        NSLog(@"jcd ws result");
        _jcdRequestAttemptsNumber = 0;
        _stations = (NSMutableArray *)[Station fromJSONArray:json];
        NSLog(@"stations count %i", _stations.count);
        if (_mapViewState == MAP_VIEW_DEFAULT_STATE) {
            [self determineSpanCoordinates];
            [self drawStationsAroundUserAndZoom];
        }
        [self startTimer];
    }];
    [_wsRequest handleExceptionWith:^(NSError *exception) {
        if (exception.code == JCD_TIMED_OUT_REQUEST_EXCEPTION_CODE) {
            NSLog(@"jcd ws exception : expired request");
            if (_jcdRequestAttemptsNumber < 2) {
                [_wsRequest call];
                _jcdRequestAttemptsNumber++;
            } else {
                [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"") message:NSLocalizedString(@"jcd_ws_get_data_error", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
            }
        }
    }];
    
    NSLog(@"call ws");
    [_wsRequest call];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    [self stopTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    // centered by default on Toulouse
    CLLocationCoordinate2D tls;
    tls.latitude = TLS_LAT;
    tls.longitude = TLS_LONG;
    
    MKCoordinateRegion viewRegion = MKCoordinateRegionMakeWithDistance(tls,
        SPAN_SIDE_INIT_LENGTH_IN_METERS, SPAN_SIDE_INIT_LENGTH_IN_METERS);
    [mapPanel setRegion:viewRegion animated:YES];
    NSLog(@"centered on Toulouse (%f,%f)", tls.latitude, tls.longitude);
}

# pragma mark Delegate

- (void)mapView:(MKMapView *)aMapView didUpdateUserLocation:(MKUserLocation *)aUserLocation {
    if (startUserLocation == nil) {
        startUserLocation = aUserLocation;
        [self centerMapOnUserLocation];
    }
}

/*- (void)mapView:(MKMapView *)aMapView regionDidChangeAnimated:(BOOL)animated {
    if (_isMapLoaded && _mapViewState == MAP_VIEW_DEFAULT_STATE) {
        NSLog(@"region has changed");
        [self determineSpanCoordinates];
        [self drawStationsAroundUserAndZoom];
    }
}*/

- (void)mapViewDidFinishLoadingMap:(MKMapView *)aMapView {
    NSLog(@"map is loaded");
    _isMapLoaded = true;
}

-(MKOverlayView *)mapView:(MKMapView *)aMapView viewForOverlay:(id<MKOverlay>)overlay
{
    NSLog(@"render route");
    RoutePolyline *polyline = overlay;
    MKPolylineView *polylineView = [[MKPolylineView alloc] initWithPolyline:polyline.polyline];
    polylineView.lineWidth = 5;
    polylineView.strokeColor = [UIColor greenColor];
    return polylineView;
}

- (MKAnnotationView *)mapView:(MKMapView *)aMapView viewForAnnotation:(id <MKAnnotation>)anAnnotation
{
    MKPinAnnotationView *annotationView;
    if (anAnnotation != mapPanel.userLocation) {
        static NSString *annotationID = @"annotation";
        annotationView = (MKPinAnnotationView *)[aMapView dequeueReusableAnnotationViewWithIdentifier:annotationID];
        if (annotationView == nil) {
            annotationView = [[MKPinAnnotationView alloc] initWithAnnotation:anAnnotation reuseIdentifier:annotationID];
        }
        if ([anAnnotation isKindOfClass:[PlaceAnnotation class]]) {
            PlaceAnnotation *annotation = anAnnotation;
            if (annotation.placeType == kDeparture) {
                NSLog(@"render departure");
                annotationView.image =  [UIImage imageNamed:@"Images/MapPanel/MPDeparture"];
            } else if (annotation.placeType == kArrival) {
                NSLog(@"render arrival");
                annotationView.image =  [UIImage imageNamed:@"Images/MapPanel/MPArrival"];
            } else {
                UIImage *background = [UIImage imageNamed:@"Images/MapPanel/MPStation"];
                UIImage *bikes = [ImageUtils drawBikesText:[annotation.placeStation.availableBikes stringValue]];
                UIImage *tmp = [ImageUtils placeBikes:bikes onImage:background];
                UIImage *stands = [ImageUtils drawStandsText:[annotation.placeStation.availableBikeStands stringValue]];
                UIImage *image = [ImageUtils placeStands:stands onImage:tmp];
                annotationView.image = image;
            
            }
        }
        annotationView.canShowCallout = YES;
    }
    return annotationView;
}

- (void)mapView:(MKMapView *)aMapView didSelectAnnotationView:(MKAnnotationView *)aView {
    if (!_isSearchViewVisible && _mapViewState == MAP_VIEW_SEARCH_STATE) {
        if ([aView.annotation isKindOfClass:[PlaceAnnotation class]]) {
            PlaceAnnotation *annotation = aView.annotation;
            if (annotation.placeType != kDeparture && annotation.placeType != kArrival && annotation.placeLocation != kUndefined) {
                BOOL redraw = false;
                if (annotation.placeLocation == kNearDeparture && _departureStation != annotation.placeStation) {
                    NSLog(@"change departure");
                    _departureStation = annotation.placeStation;
                    redraw = true;
                } else if (annotation.placeLocation == kNearArrival && _arrivalStation != annotation.placeStation) {
                    NSLog(@"change departure");
                    _arrivalStation = annotation.placeStation;
                    redraw = true;
                }
                if (redraw) {
                    [self eraseRoute];
                    [self drawRouteFromStationDeparture:_departureStation toStationArrival:_arrivalStation];
                }
            }
        }
    }
    
}

- (BOOL)textFieldShouldEndEditing:(UITextField *)textField {
    if (textField == self.bikeField) {
        if ([textField.text isEqualToString:@""]) {
            self.bikeField.text = @"1";
        } else if (textField.text.length > 2) {
            self.bikeField.text = @"99";
        }
        self.standField.text = self.bikeField.text;
    } else if (textField == self.standField) {
        if ([textField.text isEqualToString:@""]) {
            self.standField.text = @"1";
        } else if (textField.text.length > 2) {
            self.standField.text = @"99";
        }
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.departureField) {
        [self.arrivalField becomeFirstResponder];
    } else {
        [self.view endEditing:YES];
    }
    return YES;
}

# pragma mark Event(s)

-(void)timerFired:(NSTimer *)theTimer
{
    NSLog(@"timer fired %@", [theTimer fireDate]);
    NSLog(@"call ws");
    [_wsRequest call];
}

- (void)didTapMap:(UITapGestureRecognizer *)sender
{
    NSLog(@"tap map fired");
    if (_isSearchViewVisible) {
        _isSearchViewVisible = false;
        [self closeSearchPanel];
    }
    [self refreshNavigationBarHasSearchView:_isSearchViewVisible hasRideView:_mapViewState == MAP_VIEW_SEARCH_STATE];
}

- (IBAction)searchBarButtonClicked:(id)sender {
    _isSearchViewVisible = true;
    [self openSearchPanel];
    [self refreshNavigationBarHasSearchView:_isSearchViewVisible hasRideView:_mapViewState == MAP_VIEW_SEARCH_STATE];
}

- (IBAction)cancelBarButtonClicked:(id)sender {
    if (_isSearchViewVisible) {
        _isSearchViewVisible = false;
        [self closeSearchPanel];
    } else {
        _mapViewState = MAP_VIEW_DEFAULT_STATE;
        [self resetSearchViewFields];
        [self eraseRoute];
        [self centerMapOnUserLocation];
        [self drawStationsAroundUserAndZoom];
    }
    [self refreshNavigationBarHasSearchView:_isSearchViewVisible hasRideView:_mapViewState == MAP_VIEW_SEARCH_STATE];
}

- (IBAction)userLocationAsDepartureClicked:(id)sender {
    CLLocationCoordinate2D userLocation = self.mapPanel.userLocation.coordinate;
    CLLocation *location = [[CLLocation alloc] initWithLatitude:userLocation.latitude longitude:userLocation.longitude];
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray *placemarks, NSError *error) {
        if (error != nil) {
            self.departureField.text = [NSString stringWithFormat:@"%f,%f", userLocation.latitude, userLocation.longitude];
        } else {
            self.departureField.text = [[[(CLPlacemark *)[placemarks objectAtIndex:0] addressDictionary] valueForKey:@"FormattedAddressLines"] componentsJoinedByString:@", "];
        }
    }];
}

- (IBAction)userLocationAsArrivalClicked:(id)sender {
    CLLocationCoordinate2D userLocation = self.mapPanel.userLocation.coordinate;
    CLLocation *location = [[CLLocation alloc] initWithLatitude:userLocation.latitude longitude:userLocation.longitude];
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    [geocoder reverseGeocodeLocation:location completionHandler:^(NSArray *placemarks, NSError *error) {
        if (error != nil) {
            self.arrivalField.text = [NSString stringWithFormat:@"%f,%f", userLocation.latitude, userLocation.longitude];
        } else {
            self.arrivalField.text = [[[(CLPlacemark *)[placemarks objectAtIndex:0] addressDictionary] valueForKey:@"FormattedAddressLines"] componentsJoinedByString:@", "];
        }
    }];
}

- (IBAction)searchButtonClicked:(id)sender {
    [self.view endEditing:YES];
    if (self.departureField.text.length == 0) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_warning_title", @"") message:NSLocalizedString(@"missing_departure", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
    } else if (self.arrivalField.text.length == 0) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_warning_title", @"") message:NSLocalizedString(@"missing_arrival", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
    } else {
        [self.view endEditing:YES];
        _departureLocation = nil;
        _arrivalLocation = nil;
        _searching = YES;
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
        CLGeocoder *departureGeocoder = [[CLGeocoder alloc] init];
        CLGeocoder *arrivalGeocoder = [[CLGeocoder alloc] init];
        [departureGeocoder geocodeAddressString:self.departureField.text inRegion:nil completionHandler:^(NSArray *placemarks, NSError *error) {
            if (_searching) {
                if (error != nil) {
                    _searching = NO;
                    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                    [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"") message:NSLocalizedString(@"departure_not_found", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
                } else {
                    _departureLocation = [[placemarks objectAtIndex:0] location];
                    if (_departureLocation != nil && _arrivalLocation != nil) {
                        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                        if (![self areEqualLocationsBetween:_departureLocation and:_arrivalLocation]) {
                            [self cancelBarButtonClicked:nil];
                            [self searchWithDeparture:_departureLocation andArrival:_arrivalLocation withBikes:[self.bikeField.text intValue] andAvailableStands:[self.standField.text intValue] inARadiusOf:STATION_SEARCH_MAX_RADIUS_IN_METERS];
                        } else {
                            [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_warning_title", @"")  message:NSLocalizedString(@"same_location", @"") delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                        }
                    }
                }
            }
        }];
        [arrivalGeocoder geocodeAddressString:self.arrivalField.text inRegion:nil completionHandler:^(NSArray *placemarks, NSError *error) {
            if (_searching) {
                if (error != nil) {
                    _searching = NO;
                    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                    [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"") message:NSLocalizedString(@"arrival_not_found", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
                } else {
                    _arrivalLocation = [[placemarks objectAtIndex:0] location];
                    if (_departureLocation != nil && _arrivalLocation != nil) {
                        [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                        if (![self areEqualLocationsBetween:_departureLocation and:_arrivalLocation]) {
                            [self cancelBarButtonClicked:nil];
                            [self searchWithDeparture:_departureLocation andArrival:_arrivalLocation withBikes:[self.bikeField.text intValue] andAvailableStands:[self.standField.text intValue] inARadiusOf:STATION_SEARCH_MAX_RADIUS_IN_METERS];
                        } else {
                            [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_warning_title", @"")  message:NSLocalizedString(@"same_location", @"") delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                        }
                    }
                }
            }
        }];
    }
}

# pragma mark Notification(s)

- (void) didEnterBackgroundNotificationReceived:(NSNotification *)notification
{
    if ([[notification name] isEqualToString:NOTIFICATION_DID_ENTER_BACKGROUND]) {
        [self stopTimer];
    }
}

- (void) willEnterForegroundNotificationReceived:(NSNotification *)notification
{
    if ([[notification name] isEqualToString:NOTIFICATION_WILL_ENTER_FOREGROUND]) {
        double sleepingTime = [notification.object doubleValue];
        NSLog(@"sleeping time : %f s", sleepingTime);
        if (sleepingTime > TIME_BEFORE_REFRESH_DATA_IN_SECONDS) {
            NSLog(@"have to refresh stations data");
            NSLog(@"call ws");
            [_wsRequest call];
        }
    }
}

# pragma mark -
# pragma mark Navigation Bar

- (void)refreshNavigationBarHasSearchView:(BOOL)hasSearchView hasRideView:(BOOL)hasRideView {
    if (hasSearchView == false) {
        if (hasRideView == false) {
            self.navigationItem.rightBarButtonItems = nil;
            self.navigationItem.rightBarButtonItem = self.searchBarButton;
        } else {
            self.navigationItem.rightBarButtonItem = nil;
            self.navigationItem.rightBarButtonItems = @[self.cancelBarButton,self.searchBarButton];
        }
    } else {
        self.navigationItem.rightBarButtonItems = nil;
        self.navigationItem.rightBarButtonItem = nil;
    }
}

# pragma mark Map panel

- (void)centerMapOnUserLocation {
    MKCoordinateRegion currentRegion = MKCoordinateRegionMakeWithDistance(startUserLocation.coordinate, SPAN_SIDE_INIT_LENGTH_IN_METERS, SPAN_SIDE_INIT_LENGTH_IN_METERS);
    [mapPanel setRegion:currentRegion animated:YES];
    NSLog(@"centered on user location (%f,%f)", startUserLocation.coordinate.latitude, startUserLocation.coordinate.longitude);
}

- (void)centerMapOnDeparture {
    MKCoordinateRegion currentRegion = MKCoordinateRegionMakeWithDistance(_departureLocation.coordinate, SPAN_SIDE_INIT_LENGTH_IN_METERS, SPAN_SIDE_INIT_LENGTH_IN_METERS);
    [mapPanel setRegion:currentRegion animated:YES];
    NSLog(@"centered on user location (%f,%f)", _departureLocation.coordinate.latitude, _departureLocation.coordinate.longitude);
}

- (void)drawStationsAroundUserAndZoom {
    if (_stations != nil) {
        NSLog(@"display stations");
        [mapPanel removeAnnotations:mapPanel.annotations];
        int invalidStations = 0;
        int displayedStations = 0;
        for (Station *station in _stations) {
            if (station.latitude != (id)[NSNull null] && station.longitude != (id)[NSNull null]) {
                /*if ([self isVisibleStation:station]) {*/
                    [mapPanel addAnnotation:[self createStationAnnotation:station withLocation:kUndefined]];
                    displayedStations++;
                //}
            } else {
                NSLog(@"%@ : %@", station.name, station.contract);
                invalidStations++;
            }
        }
        NSLog(@"displayed stations count : %i", displayedStations);
        if (invalidStations > 0) {
            NSLog(@"invalid stations count : %i", invalidStations);
        }
    }
}

- (void)createStationsAnnotationsAroundDeparture {
    for (Station *station in _departureCloseStations) {
        [mapPanel addAnnotation:[self createStationAnnotation:station withLocation:kNearDeparture]];
    }
}

- (void)createStationsAnnotationsAroundArrival {
    for (Station *station in _arrivalCloseStations) {
        [mapPanel addAnnotation:[self createStationAnnotation:station withLocation:kNearArrival]];
    }
}

- (PlaceAnnotation *)createStationAnnotation:(Station *)aStation withLocation:(PlaceAnnotationLocation) aLocation {
    
    CLLocationCoordinate2D stationCoordinate;
    stationCoordinate.latitude = [aStation.latitude doubleValue];
    stationCoordinate.longitude = [aStation.longitude doubleValue];
    
    PlaceAnnotation *marker = [[PlaceAnnotation alloc] init];
    marker.placeLocation = aLocation;
    marker.coordinate = stationCoordinate;
    marker.title = [self cleanStationName:aStation];
    marker.placeStation = aStation;
    return marker;
}

- (BOOL)isVisibleStation:(Station *)station {
    
    BOOL visible = false;
    
    CLLocationCoordinate2D stationCoordinate;
    stationCoordinate.latitude = [station.latitude doubleValue];
    stationCoordinate.longitude = [station.longitude doubleValue];
    
    CLLocationCoordinate2D userLocation = self.mapPanel.userLocation.coordinate;
    CLLocationCoordinate2D spanCenter = self.mapPanel.region.center;
    
    if (stationCoordinate.latitude >= _northWestSpanCorner.latitude && stationCoordinate.latitude <= _southEastSpanCorner.latitude
        && stationCoordinate.longitude >= _northWestSpanCorner.longitude && stationCoordinate.longitude <= _southEastSpanCorner.longitude
        && ([self unlessInMeters:SPAN_SIDE_MAX_LENGTH_IN_METERS from:userLocation for:stationCoordinate]
            || [self unlessInMeters:SPAN_SIDE_MAX_LENGTH_IN_METERS from:spanCenter for:stationCoordinate])) {
            visible = true;
        }
    
    return visible;
}

- (void)determineSpanCoordinates {
    MKCoordinateRegion region = self.mapPanel.region;
    CLLocationCoordinate2D center = region.center;
    NSLog(@"determine span coordinates");
    _northWestSpanCorner.latitude  = center.latitude  - (region.span.latitudeDelta  / 2.0);
    _northWestSpanCorner.longitude = center.longitude - (region.span.longitudeDelta / 2.0);
    _southEastSpanCorner.latitude  = center.latitude  + (region.span.latitudeDelta  / 2.0);
    _southEastSpanCorner.longitude = center.longitude + (region.span.longitudeDelta / 2.0);
}

- (void)drawRouteEndsCloseStations {
    if ([_departureCloseStations count] == 0 || [_arrivalCloseStations count] == 0) {
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_info_title", @"")  message:NSLocalizedString(@"incomplete_search_result", @"") delegate:nil cancelButtonTitle:NSLocalizedString(@"OK", @"") otherButtonTitles:nil] show];
    }
    
    // departure annotation
    PlaceAnnotation *marker = [[PlaceAnnotation alloc] init];
    marker.placeType = kDeparture;
    marker.coordinate = _departureLocation.coordinate;
    marker.title = self.departureField.text;
    
    [mapPanel addAnnotation:marker];
    
    // arrival annotation
    marker = [[PlaceAnnotation alloc] init];
    marker.placeType = kArrival;
    marker.coordinate = _arrivalLocation.coordinate;
    marker.title = self.arrivalField.text;
    
    [mapPanel addAnnotation:marker];
    
    [self createStationsAnnotationsAroundDeparture];
    [self createStationsAnnotationsAroundArrival];
}

- (void)drawRouteFromStationDeparture:(Station *)departure toStationArrival:(Station *)arrival {
    
    NSLog(@"searching for a route");
    WSRequest *googleRequest = [[WSRequest alloc] initWithResource:GOOGLE_MAPS_WS_ENTRY_POINT_PARAM_VALUE inBackground:NO];
    [googleRequest appendParameterWithKey:GOOGLE_MAPS_API_ORIGIN_PARAM_NAME andValue:[NSString stringWithFormat:@"%@,%@", departure.latitude, departure.longitude]];
    [googleRequest appendParameterWithKey:GOOGLE_MAPS_API_DESTINATION_PARAM_NAME andValue:[NSString stringWithFormat:@"%@,%@", arrival.latitude, arrival.longitude]];
    [googleRequest appendParameterWithKey:GOOGLE_MAPS_API_LANGUAGE_PARAM_NAME andValue:[[NSLocale currentLocale] objectForKey:NSLocaleCountryCode]];
    [googleRequest appendParameterWithKey:GOOGLE_MAPS_API_MODE_PARAM_NAME andValue:@"walking"];
    [googleRequest appendParameterWithKey:GOOGLE_MAPS_API_SENSOR_PARAM_NAME andValue:@"true"];
    [googleRequest handleResultWith:^(id json) {
        NSString *status = [json valueForKey:@"status"];
        
        if ([status isEqualToString:@"OK"]) {
            NSLog(@"find a route");
            
            NSString *encodedPolyline = [[[[json objectForKey:@"routes"] firstObject] objectForKey:@"overview_polyline"] valueForKey:@"points"];
            _route = [RoutePolyline routePolylineFromPolyline:[GeoUtils polylineWithEncodedString:encodedPolyline]];
            [mapPanel addOverlay:_route];
            [mapPanel setVisibleMapRect:_route.boundingMapRect animated:YES];
            
        } else {
            NSLog(@"Google Maps API error %@", status);
            [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"")  message:@"Google Maps API error" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        }
    }];
    [googleRequest handleErrorWith:^(int errorCode) {
        NSLog(@"HTTP error %d", errorCode);
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"")  message:@"HTTP error" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    }];
    [googleRequest handleExceptionWith:^(NSError *exception) {
        NSLog(@"Exception %@", exception.debugDescription);
        [[[UIAlertView alloc] initWithTitle:NSLocalizedString(@"dialog_error_title", @"")  message:@"Exception" delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    }];
    [googleRequest call];
}

- (void)eraseRoute {
    if (_route != nil) {
        [mapPanel removeOverlay:_route];
        _route = nil;
    }
}

# pragma mark Search panel

- (void)resetSearchViewFields {
    self.departureField.text = nil;
    self.arrivalField.text = nil;
    self.bikeField.text = @"1";
    self.standField.text = @"1";
    
    _departureLocation = nil;
    _departureStation = nil;
    _arrivalLocation = nil;
    _arrivalStation = nil;
}

- (void)openSearchPanel {
    [UIView animateWithDuration:0.5 animations:^{
        CGRect searchFrame = self.searchPanel.frame;
        searchFrame.origin.y = 0;
        self.searchPanel.frame = searchFrame;
    }];
}

- (void)closeSearchPanel {
    [UIView animateWithDuration:0.5 animations:^{
        CGRect searchFrame = self.searchPanel.frame;
        searchFrame.origin.y = -searchFrame.size.height;
        self.searchPanel.frame = searchFrame;
    }];
}

- (void)searchWithDeparture:(CLLocation *)departure andArrival:(CLLocation *)arrival withBikes:(int)bikes andAvailableStands:(int)availableStands inARadiusOf:(int)radius {
    NSLog(@"%f,%f -> %f,%f (%d / %d)", departure.coordinate.latitude, departure.coordinate.longitude, arrival.coordinate.latitude, arrival.coordinate.longitude, bikes, availableStands);
    _mapViewState = MAP_VIEW_SEARCH_STATE;
    [self refreshNavigationBarHasSearchView:_isSearchViewVisible hasRideView:_mapViewState == MAP_VIEW_SEARCH_STATE];
    [_departureCloseStations removeAllObjects];
    [_arrivalCloseStations removeAllObjects];
    [self eraseRoute];
    _departureStation = nil;
    _arrivalStation = nil;
    [mapPanel removeAnnotations:mapPanel.annotations];
    [self searchCloseStationsAroundDeparture:departure withBikesNumber:bikes andMaxStationsNumber:SEARCH_RESULT_MAX_STATIONS_NUMBER inARadiusOf:radius];
    [self searchCloseStationsAroundArrival:arrival withAvailableStandsNumber:availableStands andMaxStationsNumber:SEARCH_RESULT_MAX_STATIONS_NUMBER inARadiusOf:radius];
    [self drawRouteEndsCloseStations];
    if (_departureStation != nil && _arrivalStation != nil) {
      [self drawRouteFromStationDeparture:_departureStation toStationArrival:_arrivalStation];
    } else {
        [self centerMapOnDeparture];
    }
}

- (void)searchCloseStationsAroundDeparture:(CLLocation *)location withBikesNumber:(int)bikesNumber andMaxStationsNumber:(int)maxStationsNumber inARadiusOf:(int)maxRadius {
    NSLog(@"searching %d close stations around departure", maxStationsNumber);
    int matchingStationNumber = 0;
    
    int radius = STATION_SEARCH_RADIUS_IN_METERS;
    while (matchingStationNumber < maxStationsNumber && radius <= maxRadius) {
        for (Station *station in _stations) {
            if (matchingStationNumber < maxStationsNumber) {
                if (station.latitude != (id)[NSNull null] && station.longitude != (id)[NSNull null]) {
                    
                    CLLocationCoordinate2D stationCoordinate;
                    stationCoordinate.latitude = [station.latitude doubleValue];
                    stationCoordinate.longitude = [station.longitude doubleValue];
                    
                    if (![_departureCloseStations containsObject:station] && [self unlessInMeters:radius from:location.coordinate for:stationCoordinate]) {
                        if ([station.availableBikes integerValue] >= bikesNumber) {
                            NSLog(@"close station found at %d m : %@ - %@ available bikes", radius, station.name, station.availableBikes);
                            [_departureCloseStations addObject:station];
                            if (_departureStation == nil) {
                                _departureStation = station;
                            }
                            matchingStationNumber++;
                        }
                    }
                }
            } else {
                // station max number is reached for this location
                break;
            }
        }
        radius += STATION_SEARCH_RADIUS_IN_METERS;
    }
}

- (void)searchCloseStationsAroundArrival:(CLLocation *)location withAvailableStandsNumber:(int)availableStandsNumber andMaxStationsNumber:(int)maxStationsNumber inARadiusOf:(int)maxRadius {
    NSLog(@"searching %d close stations around arrival", maxStationsNumber);
    int matchingStationNumber = 0;
    
    int radius = STATION_SEARCH_RADIUS_IN_METERS;
    while (matchingStationNumber < maxStationsNumber && radius <= maxRadius) {
        for (Station *station in _stations) {
            if (matchingStationNumber < maxStationsNumber) {
                if (station.latitude != (id)[NSNull null] && station.longitude != (id)[NSNull null]) {
                    
                    CLLocationCoordinate2D stationCoordinate;
                    stationCoordinate.latitude = [station.latitude doubleValue];
                    stationCoordinate.longitude = [station.longitude doubleValue];
                    
                    if (![_arrivalCloseStations containsObject:station] && [self unlessInMeters:radius from:location.coordinate for:stationCoordinate]) {
                        if ([station.availableBikeStands integerValue] >= availableStandsNumber) {
                            NSLog(@"close station found at %d m : %@ - %@ available stands", radius, station.name, station.availableBikeStands);
                            [_arrivalCloseStations addObject:station];
                            if (_arrivalStation == nil) {
                                _arrivalStation = station;
                            }
                            matchingStationNumber++;
                        }
                    }
                }
            } else {
                // station max number is reached for this location
                break;
            }
        }
        radius += STATION_SEARCH_RADIUS_IN_METERS;
    }
}

# pragma mark -
# pragma mark Misc

- (BOOL)unlessInMeters:(double)radius from:(CLLocationCoordinate2D)origin for:(CLLocationCoordinate2D)location {
    double dist = [GeoUtils getDistanceFromLat:origin.latitude toLat:location.latitude fromLong:origin.longitude toLong:location.longitude];
    return dist <= radius;
}

- (BOOL)areEqualLocationsBetween:(CLLocation *)first and:(CLLocation *)second {
    return fabs(first.coordinate.latitude - second.coordinate.latitude) < 0.001 &&
    fabs(first.coordinate.longitude - second.coordinate.longitude) < 0.001;
}

- (NSString *)cleanStationName:(Station *)aStation {
    NSString *regexp = @"^[a-zA-Z](.*)$";
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@",regexp];
    NSMutableString *tmp = [aStation.name mutableCopy];
    while (![predicate evaluateWithObject: tmp] || tmp.length == 0) {
        // remove first character while is not a letter
        tmp = (NSMutableString *)[tmp substringFromIndex:1];
    }
    
    NSString *result;
    if (tmp.length > 0) {
        result = [NSString stringWithString:tmp];
    } else {
        result = @"###";
    }
    return result;
}

@end
