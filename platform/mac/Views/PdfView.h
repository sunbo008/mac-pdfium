//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "public/fpdf_doc.h"
#include "public/fpdfview.h"

// PdfView的委托协议
@protocol PdfViewDelegate <NSObject>
@optional
- (void)pdfViewDidChangePage:(id)sender;
- (void)pdfViewDidClickObject:(NSValue*)objectValue atIndex:(NSNumber*)index;
@end

@interface PdfView : NSView
@property(nonatomic, assign) id<PdfViewDelegate> delegate;
- (BOOL)openPDFAtPath:(NSString*)path;
- (FPDF_DOCUMENT)document;
- (void)goToPage:(int)index;
- (int)currentPageIndex;          // 获取当前页索引（0开始）
- (NSSize)currentPageSizePt;      // 当前页 PDF 尺寸（pt）
- (void)updateViewSizeToFitPage;  // 根据页尺寸与缩放调整自身 frame
                                  // 大小（供滚动容器使用）
- (BOOL)findText:(NSString*)searchText
       fromIndex:(NSNumber*)startIndex;  // 文本查找功能
- (BOOL)exportCurrentPagePNG;            // 导出当前页为PNG
@end
