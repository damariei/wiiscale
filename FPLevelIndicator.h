//
//  FPLevelIndicator.h
//  GoogleHealthWeight
//
//  Created by Ford Parsons on 11/23/10.
//  Copyright 2010 Ford Parsons. All rights reserved.
//

@interface FPLevelIndicator : NSLevelIndicator {
	double lowCriticalValue;
	double lowWarningValue;
	double highWarningValue;
	double highCriticalValue;
}

@property double lowCriticalValue;
@property double lowWarningValue;
@property double highWarningValue;
@property double highCriticalValue;

@end
