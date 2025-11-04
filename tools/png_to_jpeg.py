#!/usr/bin/env python3
# Copyright 2025 The PDFium Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
"""
Image to JPEG Converter Tool

This tool converts various image formats (PNG, BMP, TIFF, WebP, etc.) to JPEG 
with configurable quality settings. File format is detected automatically based 
on content, not file extension.

Supports single file conversion or batch processing of directories.

Usage:
  # Convert a single file (any format)
  python3 png_to_jpeg.py input.png -o output.jpg
  python3 png_to_jpeg.py image.bmp -o output.jpg

  # Convert with quality setting
  python3 png_to_jpeg.py input.png -o output.jpg -q 95

  # Batch convert all image files in a directory
  python3 png_to_jpeg.py /path/to/images/ -o /path/to/output/

  # Convert in-place (replace original files)
  python3 png_to_jpeg.py input.png --in-place

  # Batch convert with pattern matching
  python3 png_to_jpeg.py /path/to/images/ -o /path/to/output/ -p "watermark*"
"""

import argparse
import os
import sys
import glob
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Error: PIL/Pillow is not installed.")
    print("Please install it using: pip3 install Pillow")
    sys.exit(1)


def convert_to_jpeg(input_path, output_path, quality=90, background_color=(255, 255, 255), verbose=False):
    """
    Convert an image to JPEG format.
    
    Automatically detects image format from file content (not extension).
    Supports PNG, BMP, TIFF, WebP, and other PIL-supported formats.
    
    Args:
        input_path: Path to input image file
        output_path: Path to output JPEG file
        quality: JPEG quality (1-100, default 90)
        background_color: RGB tuple for transparent areas (default white)
        verbose: Print detailed information
    
    Returns:
        Tuple of (success: bool, format: str or None)
    """
    try:
        # Open the image - PIL automatically detects format from content
        img = Image.open(input_path)
        image_format = img.format  # Get detected format (PNG, BMP, TIFF, etc.)
        
        if verbose:
            print(f"  Detected format: {image_format}, Mode: {img.mode}, Size: {img.size}")
        
        # Handle transparency by converting RGBA to RGB
        if img.mode in ('RGBA', 'LA', 'P'):
            # Create a background with specified color
            background = Image.new('RGB', img.size, background_color)
            
            # If image has transparency
            if img.mode == 'RGBA' or img.mode == 'LA':
                # Paste the image on the background using alpha channel as mask
                if img.mode == 'LA':
                    img = img.convert('RGBA')
                background.paste(img, mask=img.split()[-1])  # Use alpha channel as mask
            elif img.mode == 'P':
                # Handle palette mode with possible transparency
                if 'transparency' in img.info:
                    img = img.convert('RGBA')
                    background.paste(img, mask=img.split()[-1])
                else:
                    img = img.convert('RGB')
                    background = img
            
            img = background
        elif img.mode != 'RGB':
            # Convert other modes to RGB
            img = img.convert('RGB')
        
        # Save as JPEG
        img.save(output_path, 'JPEG', quality=quality, optimize=True)
        return True, image_format
        
    except Exception as e:
        print(f"Error converting {input_path}: {str(e)}", file=sys.stderr)
        return False, None


def process_file(input_file, output_file, quality, in_place, verbose):
    """Process a single image file. Format is auto-detected from content."""
    input_path = Path(input_file)
    
    if not input_path.exists():
        print(f"Error: Input file '{input_file}' does not exist.", file=sys.stderr)
        return False
    
    if not input_path.is_file():
        print(f"Error: '{input_file}' is not a file.", file=sys.stderr)
        return False
    
    # Determine output path
    if in_place:
        output_path = input_path.with_suffix('.jpeg')
    elif output_file:
        output_path = Path(output_file)
    else:
        output_path = input_path.with_suffix('.jpeg')
    
    # Create output directory if it doesn't exist
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    if verbose:
        print(f"Converting: {input_path} -> {output_path}")
    
    success, image_format = convert_to_jpeg(str(input_path), str(output_path), quality, verbose=verbose)
    
    if success:
        if verbose:
            input_size = input_path.stat().st_size
            output_size = output_path.stat().st_size
            compression_ratio = (1 - output_size / input_size) * 100
            print(f"  Success! Size: {input_size:,} bytes -> {output_size:,} bytes "
                  f"({compression_ratio:.1f}% reduction)")
        else:
            # Show format info even in non-verbose mode
            print(f"Converted {image_format} -> JPEG: {input_path.name}")
        
        # Delete original file if in-place mode
        if in_place and output_path != input_path:
            input_path.unlink()
            if verbose:
                print(f"  Deleted original: {input_path}")
        
        return True
    
    return False


def process_directory(input_dir, output_dir, pattern, quality, in_place, verbose):
    """Process all image files in a directory. Formats are auto-detected."""
    input_path = Path(input_dir)
    
    if not input_path.is_dir():
        print(f"Error: '{input_dir}' is not a directory.", file=sys.stderr)
        return False
    
    # Find all files matching the pattern
    if pattern:
        files = list(input_path.glob(pattern))
    else:
        # Default: common image extensions (but format is still verified by content)
        files = []
        for ext in ['*.png', '*.PNG', '*.jpg', '*.JPG', '*.jpeg', '*.JPEG', 
                    '*.bmp', '*.BMP', '*.tiff', '*.TIFF', '*.tif', '*.TIF',
                    '*.webp', '*.WEBP', '*.gif', '*.GIF']:
            files.extend(input_path.glob(ext))
        # Remove duplicates while preserving order
        seen = set()
        files = [f for f in files if not (f in seen or seen.add(f))]
    
    if not files:
        print(f"No image files found in '{input_dir}'", file=sys.stderr)
        return False
    
    print(f"Found {len(files)} image file(s) to process...")
    
    success_count = 0
    fail_count = 0
    skipped_count = 0
    
    for img_file in files:
        # Skip if it's already a JPEG
        if img_file.suffix.lower() in ['.jpg', '.jpeg']:
            if verbose:
                print(f"Skipping JPEG file: {img_file.name}")
            skipped_count += 1
            continue
        
        # Determine output path
        if output_dir:
            output_path = Path(output_dir) / img_file.with_suffix('.jpeg').name
        else:
            output_path = img_file.with_suffix('.jpeg')
        
        # Create output directory if it doesn't exist
        output_path.parent.mkdir(parents=True, exist_ok=True)
        
        if verbose:
            print(f"\nConverting: {img_file.name}")
        
        success, image_format = convert_to_jpeg(str(img_file), str(output_path), quality, verbose=verbose)
        
        if success:
            success_count += 1
            
            if verbose:
                input_size = img_file.stat().st_size
                output_size = output_path.stat().st_size
                compression_ratio = (1 - output_size / input_size) * 100
                print(f"  Success! Size: {input_size:,} bytes -> {output_size:,} bytes "
                      f"({compression_ratio:.1f}% reduction)")
            else:
                print(f"Converted {image_format} -> JPEG: {img_file.name}")
            
            # Delete original file if in-place mode
            if in_place:
                img_file.unlink()
                if verbose:
                    print(f"  Deleted original: {img_file}")
        else:
            fail_count += 1
    
    print(f"\n{'='*60}")
    print(f"Conversion complete: {success_count} succeeded, {fail_count} failed, {skipped_count} skipped")
    return fail_count == 0


def main():
    parser = argparse.ArgumentParser(
        description='Convert images to JPEG format (auto-detects format from content)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__)
    
    parser.add_argument('input',
                        help='Input image file or directory containing image files')
    
    parser.add_argument('-o', '--output',
                        help='Output JPEG file or directory (default: same as input with .jpeg extension)')
    
    parser.add_argument('-q', '--quality',
                        type=int,
                        default=90,
                        choices=range(1, 101),
                        metavar='1-100',
                        help='JPEG quality (1-100, default: 90)')
    
    parser.add_argument('-p', '--pattern',
                        help='Glob pattern for batch processing (e.g., "watermark*", "*.png")')
    
    parser.add_argument('--in-place',
                        action='store_true',
                        help='Replace original image files with JPEG versions')
    
    parser.add_argument('-v', '--verbose',
                        action='store_true',
                        help='Verbose output with conversion details')
    
    parser.add_argument('-b', '--background',
                        default='255,255,255',
                        help='Background color for transparent areas as R,G,B (default: 255,255,255 white)')
    
    args = parser.parse_args()
    
    # Validate quality
    if args.quality < 1 or args.quality > 100:
        print("Error: Quality must be between 1 and 100", file=sys.stderr)
        return 1
    
    # Parse background color
    try:
        bg_parts = args.background.split(',')
        if len(bg_parts) != 3:
            raise ValueError("Background must be R,G,B format")
        background_color = tuple(int(x.strip()) for x in bg_parts)
        if any(x < 0 or x > 255 for x in background_color):
            raise ValueError("RGB values must be 0-255")
    except ValueError as e:
        print(f"Error: Invalid background color format: {e}", file=sys.stderr)
        return 1
    
    # Check if input is a file or directory
    input_path = Path(args.input)
    
    if not input_path.exists():
        print(f"Error: '{args.input}' does not exist.", file=sys.stderr)
        return 1
    
    if input_path.is_file():
        # Single file conversion
        success = process_file(args.input, args.output, args.quality, args.in_place, args.verbose)
        return 0 if success else 1
    elif input_path.is_dir():
        # Directory batch conversion
        success = process_directory(args.input, args.output, args.pattern, 
                                    args.quality, args.in_place, args.verbose)
        return 0 if success else 1
    else:
        print(f"Error: '{args.input}' is neither a file nor a directory.", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

