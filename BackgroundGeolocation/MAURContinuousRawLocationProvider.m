//
//  MAURContinuousRawLocationProvider.m
//  BackgroundGeolocation
//
//  Created by Rob Visentin on 6/24/20.
//

#import "MAURContinuousRawLocationProvider.h"
#import "MAURLogging.h"

#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v)  ([[[UIDevice currentDevice] systemVersion] compare:v options:NSNumericSearch] != NSOrderedAscending)

#define LOCATION_DENIED         "User denied use of location services."
#define LOCATION_RESTRICTED     "Application's use of location services is restricted."
#define LOCATION_NOT_DETERMINED "User undecided on application's use of location services."

static NSString * const TAG = @"ContinuousRawLocationProvider";
static NSString * const Domain = @"com.marianhello";

enum {
    maxLocationAgeInSeconds = 30
};

@interface MAURContinuousRawLocationProvider () <CLLocationManagerDelegate>
@end

@implementation MAURContinuousRawLocationProvider {
    BOOL isUpdatingLocation;
    BOOL isStarted;

    MAUROperationalMode operationMode;

    CLLocationManager *locationManager;
    CLCircularRegion *monitoredRegion;

    // configurable options
    MAURConfig *_config;
}

- (instancetype) init
{
    self = [super init];

    if (self) {
        isUpdatingLocation = NO;
        monitoredRegion = nil;
        isStarted = NO;
    }

    return self;
}

- (void) onCreate {
    locationManager = [[CLLocationManager alloc] init];

    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"9.0")) {
        DDLogDebug(@"%@ >= iOS9 detected", TAG);
        locationManager.allowsBackgroundLocationUpdates = YES;
    }

    locationManager.delegate = self;
}

- (BOOL) onConfigure:(MAURConfig*)config error:(NSError * __autoreleasing *)outError
{
    DDLogVerbose(@"%@ configure", TAG);
    _config = config;

    locationManager.pausesLocationUpdatesAutomatically = [_config pauseLocationUpdates];
    locationManager.activityType = [_config decodeActivityType];
    locationManager.distanceFilter = _config.distanceFilter.integerValue; // meters
    locationManager.desiredAccuracy = [_config decodeDesiredAccuracy];

    return YES;
}

/**
 * Turn on background geolocation
 */
- (BOOL) onStart:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ will start", TAG);

    NSUInteger authStatus;

    if ([CLLocationManager respondsToSelector:@selector(authorizationStatus)]) { // iOS 4.2+
        authStatus = [CLLocationManager authorizationStatus];

        if (authStatus == kCLAuthorizationStatusDenied) {
            if (outError != NULL) {
                NSDictionary *errorDictionary = @{
                                                  NSLocalizedDescriptionKey: NSLocalizedString(@LOCATION_DENIED, nil)
                                                  };

                *outError = [NSError errorWithDomain:Domain code:MAURBGPermissionDenied userInfo:errorDictionary];
            }

            return NO;
        }

        if (authStatus == kCLAuthorizationStatusRestricted) {
            if (outError != NULL) {
                NSDictionary *errorDictionary = @{
                                                  NSLocalizedDescriptionKey: NSLocalizedString(@LOCATION_RESTRICTED, nil)
                                                  };
                *outError = [NSError errorWithDomain:Domain code:MAURBGPermissionDenied userInfo:errorDictionary];
            }

            return NO;
        }

#ifdef __IPHONE_8_0
        // we do startUpdatingLocation even though we might not get permissions granted
        // we can stop later on when recieved callback on user denial
        // it's neccessary to start call startUpdatingLocation in iOS < 8.0 to show user prompt!

        if (authStatus == kCLAuthorizationStatusNotDetermined) {
            if ([locationManager respondsToSelector:@selector(requestAlwaysAuthorization)]) {  //iOS 8.0+
                DDLogVerbose(@"%@ requestAlwaysAuthorization", TAG);
                [locationManager requestAlwaysAuthorization];
            }
        }
#endif
    }

    [self switchMode:MAURForegroundMode];

    isStarted = YES;

    return YES;
}

/**
 * Turn it off
 */
- (BOOL) onStop:(NSError * __autoreleasing *)outError
{
    DDLogInfo(@"%@ stop", TAG);

    [self stopUpdatingLocation];
    [self stopRegionMonitoring];
    [self stopMonitoringSignificantLocationChanges];

    isStarted = NO;

    return YES;
}

- (void) onSwitchMode:(MAUROperationalMode)mode
{
    [self switchMode:mode];
}

/**
 * toggle between foreground and background operation mode
 */
- (void) switchMode:(MAUROperationalMode)mode
{
    DDLogInfo(@"%@ switchMode %lu", TAG, (unsigned long)mode);

    operationMode = mode;

    if (operationMode == MAURForegroundMode) {
        [self stopMonitoringSignificantLocationChanges];
        [self stopRegionMonitoring];
    } else if (operationMode == MAURBackgroundMode) {
        [self startMonitoringSignificantLocationChanges];
        [self startRegionMonitoring];
    }

    if (operationMode == MAURForegroundMode || !_config.saveBatteryOnBackground) {
        [self startUpdatingLocation];
    } else {
        [self stopUpdatingLocation];
    }
}

- (void) locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    DDLogDebug(@"%@ didUpdateLocations (operationMode: %lu)", TAG, (unsigned long)operationMode);

    if (operationMode == MAURForegroundMode || !_config.saveBatteryOnBackground) {
        [self startUpdatingLocation];
    }

    if (operationMode == MAURBackgroundMode) {
        [self startMonitoringSignificantLocationChanges];

        if (monitoredRegion == nil) {
            [self startRegionMonitoring];
        }
    }

    MAURLocation *bestLocation = nil;
    for (CLLocation *location in locations) {
        MAURLocation *bgloc = [MAURLocation fromCLLocation:location];

        // test the age of the location measurement to determine if the measurement is cached
        // in most cases you will not want to rely on cached measurements
        if ([bgloc locationAge] > maxLocationAgeInSeconds || ![bgloc hasAccuracy] || ![bgloc hasTime]) {
            continue;
        }

        if (bestLocation == nil) {
            bestLocation = bgloc;
            continue;
        }

        if ([bgloc isBetterLocation:bestLocation]) {
            DDLogInfo(@"Better location found: %@", bgloc);
            bestLocation = bgloc;
        }
    }

    if (bestLocation != nil && monitoredRegion != nil && ![monitoredRegion containsCoordinate:bestLocation.coordinate]) {
        [self startRegionMonitoring];
    }

    if (bestLocation != nil) {
        [super.delegate onLocationChanged:bestLocation];
    }
}

- (void) locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region
{
    CLLocationDistance radius = [monitoredRegion radius];
    CLLocationCoordinate2D coordinate = [monitoredRegion center];

    DDLogDebug(@"%@ didExitRegion {%f,%f,%f}", TAG, coordinate.latitude, coordinate.longitude, radius);
    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (exitRegionSound);
        [self notify:@"Exit stationary region"];
    }

    MAURLocation *location = [MAURLocation fromCLLocation:manager.location];
    location.radius = [NSNumber numberWithDouble:radius];
    location.time = [NSDate date];

    [self startRegionMonitoring];

    [super.delegate onLocationChanged:location];
}

- (void) locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"%@ location updates paused", TAG);
    if ([_config isDebugging]) {
        [self notify:@"Location updates paused"];
    }
}

- (void) locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager
{
    DDLogDebug(@"%@ location updates resumed", TAG);
    if ([_config isDebugging]) {
        [self notify:@"Location updates resumed b"];
    }
}

- (void) locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    DDLogError(@"%@ didFailWithError: %@", TAG, error);
    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (locationErrorSound);
        [self notify:[NSString stringWithFormat:@"Location error: %@", error.localizedDescription]];
    }

    switch(error.code) {
        case kCLErrorLocationUnknown:
        case kCLErrorNetwork:
        case kCLErrorRegionMonitoringDenied:
        case kCLErrorRegionMonitoringSetupDelayed:
        case kCLErrorRegionMonitoringResponseDelayed:
        case kCLErrorGeocodeFoundNoResult:
        case kCLErrorGeocodeFoundPartialResult:
        case kCLErrorGeocodeCanceled:
            break;
        case kCLErrorDenied:
            break;
    }

    if (self.delegate && [self.delegate respondsToSelector:@selector(onError:)]) {
        NSDictionary *errorDictionary = @{
                                          NSUnderlyingErrorKey : error
                                          };
        NSError *outError = [NSError errorWithDomain:Domain code:MAURBGServiceError userInfo:errorDictionary];

        [self.delegate onError:outError];
    }
}

- (void) locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    DDLogInfo(@"LocationManager didChangeAuthorizationStatus %u", status);
    if ([_config isDebugging]) {
        [self notify:[NSString stringWithFormat:@"Authorization status changed %u", status]];
    }

    [self switchMode:operationMode];

    switch(status) {
        case kCLAuthorizationStatusRestricted:
        case kCLAuthorizationStatusDenied:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationDenied];
            }
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationAlways];
            }
            break;
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            if (self.delegate && [self.delegate respondsToSelector:@selector(onAuthorizationChanged:)]) {
                [self.delegate onAuthorizationChanged:MAURLocationAuthorizationForeground];
            }
            break;
        default:
            break;
    }
}

- (void) stopUpdatingLocation
{
    if (isUpdatingLocation) {
        [locationManager stopUpdatingLocation];
        isUpdatingLocation = NO;
    }
}

- (void) startUpdatingLocation
{
    if (!isUpdatingLocation) {
        [locationManager startUpdatingLocation];
        isUpdatingLocation = YES;
    }
}

- (void) onTerminate
{
    if (isStarted && !_config.stopOnTerminate) {
        [self stopUpdatingLocation];
        [self startMonitoringSignificantLocationChanges];
        [self startRegionMonitoring];
    }
}

/**
 * Creates a new circle around user and region-monitors it for exit
 */
- (void) startRegionMonitoring {
    CLLocation *location = locationManager.location;

    if (location == nil) {
        return;
    }

    CLLocationCoordinate2D coord = [location coordinate];
    DDLogDebug(@"%@ startRegionMonitoring {%f,%f,%@}", TAG, coord.latitude, coord.longitude, _config.stationaryRadius);

    if ([_config isDebugging]) {
        AudioServicesPlaySystemSound (acquiredLocationSound);
        [self notify:[NSString stringWithFormat:@"Monitoring region {%f,%f,%@}", coord.latitude, coord.longitude, _config.stationaryRadius]];
    }

    [self stopRegionMonitoring];

    monitoredRegion = [[CLCircularRegion alloc] initWithCenter:coord radius:_config.stationaryRadius.integerValue identifier:@"ContinuousRawLocation Region"];

    [locationManager startMonitoringForRegion:monitoredRegion];
}

- (void) stopRegionMonitoring
{
    if (monitoredRegion != nil) {
        [locationManager stopMonitoringForRegion:monitoredRegion];
        monitoredRegion = nil;
    }
}

- (void) startMonitoringSignificantLocationChanges
{
    [locationManager startMonitoringSignificantLocationChanges];
}

- (void) stopMonitoringSignificantLocationChanges
{
    [locationManager stopMonitoringSignificantLocationChanges];
}

- (void) notify:(NSString*)message
{
    [super notify:message];
}

- (void) onDestroy {
    DDLogInfo(@"Destroying %@ ", TAG);
    [self onStop:nil];
}

@end

