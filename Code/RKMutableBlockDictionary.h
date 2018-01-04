//
//  RKMutableBlockDictionary.h
//  RestKit
//
//  Created by Blake Watters on 8/22/11.
//  Copyright (c) 2009-2012 RestKit. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <Foundation/Foundation.h>

/**
 A dictionary capable of storing dynamic values provided
 as a Objective-C block. Otherwise identical in functionality
 to a vanilla NSMutableDictionary
 */
@interface RKMutableBlockDictionary : NSMutableDictionary {
    @private
    NSMutableDictionary *_mutableDictionary;
}

/**
 Assigns a block as the value for a key in the dictionary. This allows you
 to implement simple logic using key-value coding semantics within the dictionary.

 When valueForKey: is invoked on the dictionary for a key with a block value, the
 block will be evaluated and the result returned.

 @param block An Objective-C block returning an id and accepting no parameters
 @param key An NSString key for setting the
 */
- (void)setValueWithBlock:(id (^)(void))block forKey:(NSString *)key;

@end
