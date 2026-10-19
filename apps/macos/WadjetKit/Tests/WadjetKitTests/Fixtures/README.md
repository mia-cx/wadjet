Canvas render fixtures are independent of `CanvasDocument.flatten`.

- `composition.png` is 12 × 8, with literal top-to-bottom pixel rows below. R is red, B blue, G green, W white, C cyan, Y yellow; every pixel is opaque. It describes a crop across two displays, an overlapping window pair, then horizontal white and vertical cyan Lines. Tests allow 0.01 linear component error.

  ```text
  RRRCCRBBBBBB
  RRRCCRBBBBBB
  RRRCCRBBYYBB
  RRRCCRBBYYBB
  RRRCCRGGGGGG
  WWWCCWWWWWWW
  WWWCCWWWWWWW
  RRRCCRGGGGGG
  ```

- `rounded.png` is a white 16 × 16 square with four-pixel circular corners. Alpha is the fraction of each pixel inside the circle, independently integrated with a 256 × 256 grid per pixel, then quantized to 8 bits. Tests allow 0.04 premultiplied linear component error for CoreGraphics' curve approximation and antialiasing.
