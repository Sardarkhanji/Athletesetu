# Weight OCR benchmark

Put scale-display photos here. They are git-ignored: never commit them
(internet images are third-party copyright; your own photos may show people).

## File naming

The true reading goes first, then `__`, then any label:

    72.4__lcd_green_backlight.jpg
    48.0__led_red_01.png
    105.6__phone_photo_angle.jpg

Formats: .jpg .jpeg .png .webp

## Crop each photo to the display

In the app the assessor drags a box around the digits. Mimic that: crop each
image to the digit window (a little margin is fine, no buttons or brand text).
Keep the `kg` label if it sits beside the digits; the reader ignores it.

## Run

    flutter test test/weight_ocr_benchmark_test.dart

It prints one line per image and a summary, and writes
`test_data/weight/results.csv`. It never fails the build: it is a measurement.
