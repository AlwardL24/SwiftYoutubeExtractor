import Foundation
import JavaScriptCore

public class YoutubeExtractor {
    public struct Format {
        public let filesize: Int?
        
        public let itag: String?
        
        public let quality: String?
        public let qualityDescription: String?
        public let sampleRate: Int?
        public let bitrate: Float?
        
        public let width: Int?
        public let height: Int?
        
        public let url: URL
        public let fileExtension: String?
        public let mimeType: String?
    }
    
    struct PlayerID: Hashable, Equatable {
        var url: URL
        var signatureHash: String
    }
    
    public enum YoutubeExtractorError: Error {
        case cannotExtractSignatureFunction
        case failedToCallSignatureFunction
        case failedToStartJSContext
        case cannotExtractPlayerInfo
        case badVideoID
        case cannotParsePlayerResponse
    }
    
    typealias SignatureFunction = (_ signature: String) throws -> String
    
    var playerCache: [PlayerID: SignatureFunction] = [:]
    
    public init() {}
    
    public func formats(for videoId: String) async throws -> [Format] {
        func parse(queryString: String) -> [String: Any] {
            var queryString = queryString
            
            var dict: [String: Any] = [:]
            
            if queryString.starts(with: "?") {
                queryString.removeFirst()
            }
            
            let pairs = queryString.split(separator: "&")
            
            for pair in pairs {
                let pair = pair.split(separator: "=")
                
                guard
                    let key = pair.first,
                    let value = pair.last?.removingPercentEncoding
                else { continue }
                
                if let existingValue = dict[String(key)] {
                    if var existingValue = existingValue as? [Any] {
                        existingValue.append(String(value))
                        dict[String(key)] = existingValue
                    } else {
                        dict[String(key)] = [existingValue, String(value)]
                    }
                } else {
                    dict[String(key)] = String(value)
                }
            }
            
            return dict
        }
        
        func extractPlayerURL(from webpage: String) -> URL? {
            let webpageRange = NSRange(webpage.startIndex..., in: webpage)
            
            let regex = try! NSRegularExpression(pattern: "\"(?:PLAYER_JS_URL|jsUrl)\"\\s*:\\s*\"([^\"]+)\"")
            
            guard
                let match = regex.firstMatch(in: webpage, options: [], range: webpageRange),
                match.numberOfRanges > 1,
                let swiftRange = Range(match.range(at: 1), in: webpage)
            else { return nil }
            
            var playerURLString = String(webpage[swiftRange])
            
            if playerURLString.starts(with: "\\/\\/") {
                playerURLString = "https:" + playerURLString
            } else if !playerURLString.starts(with: "https?:") {
                playerURLString = baseURL + playerURLString
            }
            
            return URL(string: playerURLString)
        }
        
        func decrypt(signature: String, videoId: String, playerURL: URL) async throws -> String {
            let playerId = PlayerID(url: playerURL, signatureHash: signature.split(separator: ".").map { String(String($0).count) }.joined(separator: "."))
            
            if !playerCache.keys.contains(playerId) {
                let function = try await extractSignatureFunction(videoId: videoId, playerURL: playerURL, signature: signature)
                playerCache[playerId] = function
            }
            let function = playerCache[playerId]!
            
            return try function(signature)
        }
        
        func extractSignatureFunction(videoId: String, playerURL: URL, signature: String) async throws -> SignatureFunction {
            // Make a request to the player url
            let (data, _) = try await URLSession.shared.data(from: playerURL)
            let playerCode = String(decoding: data, as: UTF8.self)
            
            let regexes = [
                #"\b[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#,
                #"\b[a-zA-Z0-9]+\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]+)\("#,
                #"\bm=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(h\.s\)\)"#,
                #"\bc&&\(c=([a-zA-Z0-9$]{2,})\(decodeURIComponent\(c\)\)"#,
                #"(?:\b|[^a-zA-Z0-9$])([a-zA-Z0-9$]{2,})\s*=\s*function\(\s*a\s*\)\s*{\s*a\s*=\s*a\.split\(\s*""\s*\)(?:;[a-zA-Z0-9$]{2}\.[a-zA-Z0-9$]{2}\(a,\d+\))?"#,
                #"([a-zA-Z0-9$]+)\s*=\s*function\(\s*a\s*\)\s*{\s*a\s*=\s*a\.split\(\s*""\s*\)"#,
                #"(?:"|\')signature\1\s*,\s*([a-zA-Z0-9$]+)\("#,
                #"\.sig\|\|([a-zA-Z0-9$]+)\("#,
                #"yt\.akamaized\.net/\)\s*\|\|\s*.*?\s*[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*(?:encodeURIComponent\s*\()?\s*([a-zA-Z0-9$]+)\("#,
                #"\b[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*([a-zA-Z0-9$]+)\("#,
                #"\b[a-zA-Z0-9]+\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*([a-zA-Z0-9$]+)\("#,
                #"\bc\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*\([^)]*\)\s*\(\s*([a-zA-Z0-9$]+)\("#,
            ]
            
            var signatureFunctionName: String?
            
            for regex in regexes {
                let regex = try! NSRegularExpression(pattern: regex)
                
                guard
                    let match = regex.firstMatch(in: playerCode, options: [], range: NSRange(playerCode.startIndex..., in: playerCode)),
                    match.numberOfRanges > 1,
                    let swiftRange = Range(match.range(at: 1), in: playerCode)
                else { continue }
                
                signatureFunctionName = String(playerCode[swiftRange])
                break
            }
            
            guard let signatureFunctionName = signatureFunctionName else {
                throw YoutubeExtractorError.cannotExtractSignatureFunction
            }
            
            let returnSignatureFunctionRegex = #"\}\s*\)\s*\(\s*_yt_player\s*\);$"#
            var parsedPlayerCode = playerCode.replacingOccurrences(of: returnSignatureFunctionRegex, with: "return \(signatureFunctionName);$0", options: .regularExpression)
            
            let windowVariableRegex = #"var\s+window\s*=\s*this"#
            parsedPlayerCode = parsedPlayerCode.replacingOccurrences(of: windowVariableRegex, with: "", options: .regularExpression)
            
            let browserVariables = "var document = null;var XMLHttpRequest = { prototype: { fetch: null } };var navigator = { mediaCapabilities: null };var window = { location: { hostname: \"\" } }"  // Trick the JS code into thinking it's running in the browser - otherwise the interpreter will raise TypeErrors
            
            let functionVariableRegex = #"(var\s+_yt_player\s*=\s*\{\s*\};\s*)(\(function\s*\()"#
            parsedPlayerCode = parsedPlayerCode.replacingOccurrences(of: functionVariableRegex, with: "$1\(browserVariables);var _youtube_extractor_function = $2", options: .regularExpression)
            
            if let context = JSContext() {
                context.evaluateScript(parsedPlayerCode)
                guard let jsFunction = context.objectForKeyedSubscript("_youtube_extractor_function") else { throw YoutubeExtractorError.cannotExtractSignatureFunction }
                
                return { signature in
                    guard let result = jsFunction.call(withArguments: [signature]) else { throw YoutubeExtractorError.failedToCallSignatureFunction }
                    return result.toString()
                }
            }
            
            throw YoutubeExtractorError.failedToStartJSContext
        }
        
        let baseURL = "https://youtube.com/"
        
        // download the webpage
        
        guard let webpageURL = URL(string: baseURL + "watch?v=" + videoId) else {
            throw YoutubeExtractorError.badVideoID
        }
        
        let (data, _) = try await URLSession.shared.data(from: webpageURL)
        
        let webpage = String(decoding: data, as: UTF8.self)
        
        // get player response
        
        let _YT_INITIAL_PLAYER_RESPONSE_RE = "ytInitialPlayerResponse\\s*=\\s*(\\{.+?\\})\\s*;"
        let _YT_INITIAL_BOUNDARY_RE = "(?:var\\s+meta|<\\/script|\\n)"
        
        let patterns = [
            "\(_YT_INITIAL_PLAYER_RESPONSE_RE)\\s*\(_YT_INITIAL_BOUNDARY_RE)",
            _YT_INITIAL_PLAYER_RESPONSE_RE
        ]
        
        let webpageRange = NSRange(webpage.startIndex..., in: webpage)
        
        var playerResponseJSON: String?
        
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            
            guard
                let match = regex.firstMatch(in: webpage, options: [], range: webpageRange),
                match.numberOfRanges > 1
            else { continue }
            
            let range = match.range(at: 1)
            
            guard let swiftRange = Range(range, in: webpage) else { continue }
            
            playerResponseJSON = String(webpage[swiftRange])
            
            break
        }
        
        guard
            let playerResponseJSON = playerResponseJSON,
            let playerResponse = try? JSONSerialization.jsonObject(with: Data(playerResponseJSON.utf8), options: []) as? [String: Any]
        else {
            // TODO: Call api - see https://github.com/ytdl-org/youtube-dl/blob/master/youtube_dl/extractor/youtube.py#L1859
            throw YoutubeExtractorError.cannotParsePlayerResponse
        }
        
        guard
            let streamingData = playerResponse["streamingData"] as? [String: Any],
            let streamingFormats = streamingData["formats"] as? [[String: Any]],
            let adaptiveFormats = streamingData["adaptiveFormats"] as? [[String: Any]]
        else {
            throw YoutubeExtractorError.cannotParsePlayerResponse
        }
        
        let allFormats = streamingFormats + adaptiveFormats
        
        var formats: [Format] = []
        var itags: [String] = []
        var itagQualities: [String: String] = [:]
        
        var playerURL: URL?
        
        for format in allFormats {
            guard
                format["targetDurationSec"] == nil,
                format["drmFamilies"] == nil,
                format["type"] as? String != "FORMAT_STREAM_TYPE_OTF"
            else { continue }
            
            let itag = format["itag"] as? String
            let quality = format["quality"] as? String
            
            if
                let itag = itag,
                let quality = quality
            {
                itags.append(itag)
                itagQualities[itag] = quality
            }
            
            var url = URL(string: (format["url"] as? String) ?? "")
            
            if url == nil {
                guard
                    let signatureCipher = format["signatureCipher"] as? String
                else { continue }
                
                let parsedSignatureCipher = parse(queryString: signatureCipher)
                
                var _url = URL(string: parsedSignatureCipher["url"] as? String ?? "")
                var encryptedSignature = parsedSignatureCipher["s"] as? String
                
                if
                    _url == nil,
                    let _urls = parsedSignatureCipher["url"] as? [String]
                {
                    _url = URL(string: _urls.first ?? "")
                }
                
                if
                    encryptedSignature == nil,
                    let _encryptedSignatures = parsedSignatureCipher["s"] as? [String]
                {
                    encryptedSignature = _encryptedSignatures.first
                }
                
                guard
                    let _url = _url,
                    let encryptedSignature = encryptedSignature
                else { continue }
                
                url = _url
                
                // Cannot decrypt signature without playerURL
                if playerURL == nil {
                    playerURL = extractPlayerURL(from: webpage)
                }
                guard let playerURL = playerURL else { continue }
                
                let signature = try await decrypt(signature: encryptedSignature, videoId: videoId, playerURL: playerURL)
                
                var sp = parsedSignatureCipher["sp"] as? String
                if
                    sp == nil,
                    let sps = parsedSignatureCipher["sp"] as? [String]
                {
                    sp = sps.first
                }
                sp = sp ?? "signature"
                
                guard let sp = sp else { fatalError("\(#line): Impossible") }
                
                var components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
                if components.queryItems == nil {
                    components.queryItems = []
                }
                components.queryItems?.append(URLQueryItem(name: sp, value: signature))
                
                url = components.url
            }
            
            guard
                let url = url
            else { fatalError("\(#line): IMPOSSIBLE") }
            
            if let itag = itag {
                itags.append(itag)
            }
            
            func parseInt(_ int: Any?) -> Int? {
                guard let int = int else { return nil }
                
                if let int = int as? Int {
                    return int
                } else if let int = int as? String {
                    return Int(int)
                }
                
                return nil
            }
            
            func getFileExtension(from mimeType: String) -> String? {
                guard let mimeType = mimeType.split(separator: ";").first else { return nil }
                
                // first part dependent extensions
                let fileExtension = [
                    "audio/mp4": "m4a",
                    "audio/mpeg": "mp3",
                ][mimeType]
                if let fileExtension = fileExtension {
                    return fileExtension
                }
                
                guard let _secondPart = mimeType.split(separator: "/").last else { return nil }
                let secondPart = String(_secondPart)
                
                return [
                    "3gpp": "3gp",
                    "smptett+xml": "tt",
                    "ttaf+xml": "dfxp",
                    "ttml+xml": "ttml",
                    "x-flv": "flv",
                    "x-mp4-fragmented": "mp4",
                    "x-ms-sami": "sami",
                    "x-ms-wmv": "wmv",
                    "mpegurl": "m3u8",
                    "x-mpegurl": "m3u8",
                    "vnd.apple.mpegurl": "m3u8",
                    "dash+xml": "mpd",
                    "f4m+xml": "f4m",
                    "hds+xml": "f4m",
                    "vnd.ms-sstr+xml": "ism",
                    "quicktime": "mov",
                    "mp2t": "ts",
                    "x-wav": "wav"
                ][secondPart] ?? secondPart
            }
            
            var fileExtension: String?
            
            if let mimeType = format["mimeType"] as? String {
                fileExtension = getFileExtension(from: mimeType)
            }
            
            var bitrate = format["averageBitrate"] as? Float ?? format["bitrate"] as? Float
            if let _bitrate = bitrate {
                bitrate = _bitrate / 1000 // Kb/s rather than b/s
            }
            
            let _format = Format(
                filesize: parseInt(format["contentLength"]),
                itag: itag,
                quality: quality, // options are ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'hd2880', 'highres']
                qualityDescription: (format["qualityLabel"] as? String) ?? quality,
                sampleRate: parseInt(format["audioSampleRate"]),
                bitrate: bitrate,
                width: parseInt(format["width"]),
                height: parseInt(format["height"]),
                url: url,
                fileExtension: fileExtension,
                mimeType: format["mimeType"] as? String
            )
            
            formats.append(_format)
        }
        
        return formats
    }
}
