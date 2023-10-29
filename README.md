#  SwiftYoutubeExtractor

A Swift package to extract format URLs for Youtube videos. Fully Swift implementation of a (very small) subset of [youtube-dl](https://github.com/ytdl-org/youtube-dl)'s features.

## Installation

Install using the Swift Package Manager:

```swift
.package(
    url: "https://github.com/AlwardL24/SwiftYoutubeExtractor.git",
    .upToNextMajor(from: "1.0.0")
)
```

Or in Xcode, go to `File -> Add Package Dependencies...` and enter the URL:

```
https://github.com/AlwardL24/SwiftYoutubeExtractor.git
```

## Usage

```swift
import SwiftYoutubeExtractor

let extractor = YoutubeExtractor()

Task {
    let formats = try await extractor.formats(for: "dQw4w9WgXcQ")

    print(formats)
}
```
