//
//  FileShareServiceItem.m
//  iShare
//
//  Created by Jin Jin on 12-8-26.
//  Copyright (c) 2012年 Jin Jin. All rights reserved.
//

#import "FileShareServiceItem.h"

@implementation FileShareServiceItem

-(NSString*)filename{
    return (self.originalFileName)?self.originalFileName:[self.filePath lastPathComponent];
}

@end
