//
//  MapController.h
//  velibnroses
//
//  Created by Thomas on 04/07/13.
//  Copyright (c) 2013 OneLight Studio. All rights reserved.
//

#import <MapKit/MapKit.h>

@interface MapController : UIViewController <MKMapViewDelegate, UITextFieldDelegate>

@property (weak, nonatomic) IBOutlet MKMapView *mapView;
@property (weak, nonatomic) IBOutlet UIView *searchView;
@property (weak, nonatomic) IBOutlet UITextField *departureField;
@property (weak, nonatomic) IBOutlet UITextField *arrivalField;
@property (weak, nonatomic) IBOutlet UITextField *bikeField;
@property (weak, nonatomic) IBOutlet UIStepper *bikeStepper;
@property (weak, nonatomic) IBOutlet UITextField *emptyStandField;
@property (weak, nonatomic) IBOutlet UIStepper *emptyStandStepper;
@property (weak, nonatomic) IBOutlet UITextField *radiusField;
@property (weak, nonatomic) IBOutlet UIStepper *radiusStepper;
@property (strong, nonatomic) IBOutlet UIBarButtonItem *searchButton;
@property (strong, nonatomic) IBOutlet UIBarButtonItem *cancelButton;

- (IBAction)bikesChanged:(UIStepper *)stepper;
- (IBAction)emptyStandChanged:(UIStepper *)stepper;
- (IBAction)radiusChanged:(UIStepper *)stepper;
- (IBAction)displaySearchView:(id)sender;
- (IBAction)useMyLocationAsDeparture:(id)sender;
- (IBAction)useMyLocationAsArrival:(id)sender;
- (IBAction)validateSearch:(id)sender;

@end
