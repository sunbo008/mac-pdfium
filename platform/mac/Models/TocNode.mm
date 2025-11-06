//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "TocNode.h"
#include <vector>

@implementation TocNode
@end

NSString* BookmarkTitle(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm) {
  int len = FPDFBookmark_GetTitle(bm, nullptr, 0);
  if (len <= 0) {
    return @"";
  }
  std::vector<unsigned short> w((size_t)len + 1, 0);
  FPDFBookmark_GetTitle(bm, (unsigned short*)w.data(), len);
  return [[NSString alloc] initWithCharacters:(unichar*)w.data()
                                       length:(NSUInteger)len];
}

int BookmarkPage(FPDF_DOCUMENT doc, FPDF_BOOKMARK bm) {
  FPDF_DEST dest = FPDFBookmark_GetDest(doc, bm);
  if (!dest) {
    FPDF_ACTION act = FPDFBookmark_GetAction(bm);
    if (act) {
      dest = FPDFAction_GetDest(doc, act);
    }
  }
  if (!dest) {
    return -1;
  }
  return FPDFDest_GetDestPageIndex(doc, dest);
}

void BuildBookmarkChildren(FPDF_DOCUMENT doc,
                           FPDF_BOOKMARK parentBm,
                           TocNode* parentNode) {
  FPDF_BOOKMARK child = FPDFBookmark_GetFirstChild(doc, parentBm);
  while (child) {
    TocNode* node = [TocNode new];
    node.title = BookmarkTitle(doc, child);
    node.pageIndex = BookmarkPage(doc, child);
    node.children = [NSMutableArray new];
    [parentNode.children addObject:node];
    // 递归
    BuildBookmarkChildren(doc, child, node);
    child = FPDFBookmark_GetNextSibling(doc, child);
  }
}

TocNode* BuildBookmarksTree(FPDF_DOCUMENT doc) {
  TocNode* root = [TocNode new];
  root.title = @"ROOT";
  root.pageIndex = -1;
  root.children = [NSMutableArray new];
  BuildBookmarkChildren(doc, nullptr, root);
  return root;
}
