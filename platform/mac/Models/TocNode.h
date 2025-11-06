//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Foundation/Foundation.h>
#include "public/fpdf_doc.h"
#include "public/fpdfview.h"

@interface TocNode : NSObject
@property(nonatomic, strong) NSString* title;
@property(nonatomic, assign) int pageIndex;  // -1 表示无跳转
@property(nonatomic, strong) NSMutableArray<TocNode*>* children;
@end

// 书签辅助函数
NSString* BookmarkTitle(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm);
int BookmarkPage(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm);
void BuildBookmarkChildren(FPDF_DOCUMENT doc,
                           FPDF_BOOKMARK parentBm,
                           TocNode* parentNode);
TocNode* BuildBookmarksTree(FPDF_DOCUMENT doc);
