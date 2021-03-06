//
//  String+SourceKitten.swift
//  SourceKitten
//
//  Created by JP Simard on 2015-01-05.
//  Copyright (c) 2015 SourceKitten. All rights reserved.
//

import Foundation

// swiftlint:disable file_length
// This file could easily be split up

/// Representation of line in String
public struct Line {
    /// origin = 0
    public let index: Int
    /// Content
    public let content: String
    /// UTF16 based range in entire String. Equivalent to Range<UTF16Index>
    public let range: NSRange
    /// Byte based range in entire String. Equivalent to Range<UTF8Index>
    public let byteRange: NSRange
}

/**
 * For "wall of asterisk" comment blocks, such as this one.
 */
private let commentLinePrefixCharacterSet: CharacterSet = {
    var characterSet = CharacterSet.whitespacesAndNewlines
    characterSet.insert(charactersIn: "*")
    return characterSet
}()

private var keyCacheContainer = 0

extension NSString {
    /**
    CacheContainer caches:

    - UTF16-based NSRange
    - UTF8-based NSRange
    - Line
    */
    private class CacheContainer {
        let lines: [Line]
        let utf8View: String.UTF8View

        init(_ string: NSString) {
            // Make a copy of the string to avoid holding a circular reference, which would leak
            // memory.
            //
            // If the string is a `Swift.String`, strongly referencing that in `CacheContainer` does
            // not cause a circular reference, because casting `String` to `NSString` makes a new
            // `NSString` instance.
            //
            // If the string is a native `NSString` instance, a circular reference is created when
            // assigning `self.utf8View = (string as String).utf8`.
            //
            // A reference to `NSString` is held by every cast `String` along with their views and
            // indices.
            let string = (string.mutableCopy() as! NSMutableString).bridge()
            utf8View = string.utf8

            var utf16CountSoFar = 0
            var bytesSoFar = 0
            var lines = [Line]()
            let lineContents = string.components(separatedBy: .newlines)
            // Be compatible with `NSString.getLineStart(_:end:contentsEnd:forRange:)`
            let endsWithNewLineCharacter: Bool
            if let lastChar = string.utf16.last,
                let lastCharScalar = UnicodeScalar(lastChar) {
                endsWithNewLineCharacter = CharacterSet.newlines.contains(lastCharScalar)
            } else {
                endsWithNewLineCharacter = false
            }
            // if string ends with new line character, no empty line is generated after that.
            let enumerator = endsWithNewLineCharacter
                ? AnySequence(lineContents.dropLast().enumerated())
                : AnySequence(lineContents.enumerated())
            for (index, content) in enumerator {
                let index = index + 1
                let rangeStart = utf16CountSoFar
                let utf16Count = content.utf16.count
                utf16CountSoFar += utf16Count

                let byteRangeStart = bytesSoFar
                let byteCount = content.lengthOfBytes(using: .utf8)
                bytesSoFar += byteCount

                let newlineLength = index != lineContents.count ? 1 : 0 // FIXME: assumes \n

                let line = Line(
                    index: index,
                    content: content,
                    range: NSRange(location: rangeStart, length: utf16Count + newlineLength),
                    byteRange: NSRange(location: byteRangeStart, length: byteCount + newlineLength)
                )
                lines.append(line)

                utf16CountSoFar += newlineLength
                bytesSoFar += newlineLength
            }
            self.lines = lines
        }

        /**
        Returns UTF16 offset from UTF8 offset.

        - parameter byteOffset: UTF8-based offset of string.

        - returns: UTF16 based offset of string.
        */
        func location(fromByteOffset byteOffset: Int) -> Int {
            if lines.isEmpty {
                return 0
            }
            let index = lines.index(where: { NSLocationInRange(byteOffset, $0.byteRange) })
            // byteOffset may be out of bounds when sourcekitd points end of string.
            guard let line = (index.map { lines[$0] } ?? lines.last) else {
                fatalError()
            }
            let diff = byteOffset - line.byteRange.location
            if diff == 0 {
                return line.range.location
            } else if line.byteRange.length == diff {
                return NSMaxRange(line.range)
            }
            let utf8View = line.content.utf8
            let endUTF16index = utf8View.index(utf8View.startIndex, offsetBy: diff, limitedBy: utf8View.endIndex)!
                .samePosition(in: line.content.utf16)!
            let utf16Diff = line.content.utf16.distance(from: line.content.utf16.startIndex, to: endUTF16index)
            return line.range.location + utf16Diff
        }

        /**
        Returns UTF8 offset from UTF16 offset.

        - parameter location: UTF16-based offset of string.

        - returns: UTF8 based offset of string.
        */
        func byteOffset(fromLocation location: Int) -> Int {
            if lines.isEmpty {
                return 0
            }
            let index = lines.index(where: { NSLocationInRange(location, $0.range) })
            // location may be out of bounds when NSRegularExpression points end of string.
            guard let line = (index.map { lines[$0] } ?? lines.last) else {
                fatalError()
            }
            let diff = location - line.range.location
            if diff == 0 {
                return line.byteRange.location
            } else if line.range.length == diff {
                return NSMaxRange(line.byteRange)
            }
            let utf16View = line.content.utf16
            let endUTF8index = utf16View.index(utf16View.startIndex, offsetBy: diff, limitedBy: utf16View.endIndex)!
                .samePosition(in: line.content.utf8)!
            let byteDiff = line.content.utf8.distance(from: line.content.utf8.startIndex, to: endUTF8index)
            return line.byteRange.location + byteDiff
        }

        func lineAndCharacter(forCharacterOffset offset: Int) -> (line: Int, character: Int)? {
            let index = lines.index(where: { NSLocationInRange(offset, $0.range) })
            return index.map {
                let line = lines[$0]
                return (line: line.index, character: offset - line.range.location + 1)
            }
        }

        func lineAndCharacter(forByteOffset offset: Int) -> (line: Int, character: Int)? {
            let index = lines.index(where: { NSLocationInRange(offset, $0.byteRange) })
            return index.map {
                let line = lines[$0]

                let character: Int
                let content = line.content
                let length = offset - line.byteRange.location + 1
                if length == line.byteRange.length {
                    character = content.utf16.count
                } else {
                    let utf8View = content.utf8
                    let endIndex = utf8View.index(utf8View.startIndex, offsetBy: length, limitedBy: utf8View.endIndex)!
                        .samePosition(in: content.utf16)!
                    character = content.utf16.distance(from: content.utf16.startIndex, to: endIndex)
                }
                return (line: line.index, character: character)
            }
        }
    }

    /**
    CacheContainer instance is stored to instance of NSString as associated object.
    */
    private var cacheContainer: CacheContainer {
        #if os(Linux)
        return CacheContainer(self)
        #else
        if let cache = objc_getAssociatedObject(self, &keyCacheContainer) as? CacheContainer {
            return cache
        }
        let cache = CacheContainer(self)
        objc_setAssociatedObject(self, &keyCacheContainer, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return cache
        #endif
    }

    /**
    Returns line number and character for utf16 based offset.

    - parameter offset: utf16 based index.
    */
    public func lineAndCharacter(forCharacterOffset offset: Int) -> (line: Int, character: Int)? {
        return cacheContainer.lineAndCharacter(forCharacterOffset: offset)
    }

    /**
    Returns line number and character for byte offset.

    - parameter offset: byte offset.
    */
    public func lineAndCharacter(forByteOffset offset: Int) -> (line: Int, character: Int)? {
        return cacheContainer.lineAndCharacter(forByteOffset: offset)
    }

    /**
    Returns a copy of `self` with the trailing contiguous characters belonging to `characterSet`
    removed.

    - parameter characterSet: Character set to check for membership.
    */
    public func trimmingTrailingCharacters(in characterSet: CharacterSet) -> String {
        guard length > 0 else {
            return ""
        }
        var unicodeScalars = self.bridge().unicodeScalars
        while let scalar = unicodeScalars.last {
            if !characterSet.contains(scalar) {
                return String(unicodeScalars)
            }
            unicodeScalars.removeLast()
        }
        return ""
    }

    /**
    Returns self represented as an absolute path.

    - parameter rootDirectory: Absolute parent path if not already an absolute path.
    */
    public func absolutePathRepresentation(rootDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        if isAbsolutePath { return bridge() }
        #if os(Linux)
        return NSURL(fileURLWithPath: NSURL.fileURL(withPathComponents: [rootDirectory, bridge()])!.path).standardizingPath!.path
        #else
        return NSString.path(withComponents: [rootDirectory, bridge()]).bridge().standardizingPath
        #endif
    }

    /**
    Converts a range of byte offsets in `self` to an `NSRange` suitable for filtering `self` as an
    `NSString`.

    - parameter start: Starting byte offset.
    - parameter length: Length of bytes to include in range.

    - returns: An equivalent `NSRange`.
    */
    public func byteRangeToNSRange(start: Int, length: Int) -> NSRange? {
        if self.length == 0 { return nil }
        let utf16Start = cacheContainer.location(fromByteOffset: start)
        if length == 0 {
            return NSRange(location: utf16Start, length: 0)
        }
        let utf16End = cacheContainer.location(fromByteOffset: start + length)
        return NSRange(location: utf16Start, length: utf16End - utf16Start)
    }

    /**
    Converts an `NSRange` suitable for filtering `self` as an
    `NSString` to a range of byte offsets in `self`.

    - parameter start: Starting character index in the string.
    - parameter length: Number of characters to include in range.

    - returns: An equivalent `NSRange`.
    */
    public func NSRangeToByteRange(start: Int, length: Int) -> NSRange? {
        let string = bridge()

        let utf16View = string.utf16
        let startUTF16Index = utf16View.index(utf16View.startIndex, offsetBy: start)
        let endUTF16Index = utf16View.index(startUTF16Index, offsetBy: length)

        let utf8View = string.utf8
        guard let startUTF8Index = startUTF16Index.samePosition(in: utf8View),
            let endUTF8Index = endUTF16Index.samePosition(in: utf8View) else {
                return nil
        }

        // Don't using `CacheContainer` if string is short.
        // There are two reasons for:
        // 1. Avoid using associatedObject on NSTaggedPointerString (< 7 bytes) because that does
        //    not free associatedObject.
        // 2. Using cache is overkill for short string.
        let byteOffset: Int
        if utf16View.count > 50 {
            byteOffset = cacheContainer.byteOffset(fromLocation: start)
        } else {
            byteOffset = utf8View.distance(from: utf8View.startIndex, to: startUTF8Index)
        }

        // `cacheContainer` will hit for below, but that will be calculated from startUTF8Index
        // in most case.
        let length = utf8View.distance(from: startUTF8Index, to: endUTF8Index)
        return NSRange(location: byteOffset, length: length)
    }

    /**
    Returns a substring with the provided byte range.

    - parameter start: Starting byte offset.
    - parameter length: Length of bytes to include in range.
    */
    public func substringWithByteRange(start: Int, length: Int) -> String? {
        return byteRangeToNSRange(start: start, length: length).map(substring)
    }

    /**
    Returns a substring starting at the beginning of `start`'s line and ending at the end of `end`'s
    line. Returns `start`'s entire line if `end` is nil.

    - parameter start: Starting byte offset.
    - parameter length: Length of bytes to include in range.
    */
    public func substringLinesWithByteRange(start: Int, length: Int) -> String? {
        return byteRangeToNSRange(start: start, length: length).map { range in
            var lineStart = 0, lineEnd = 0
            getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: range)
            return substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        }
    }

    public func substringStartingLinesWithByteRange(start: Int, length: Int) -> String? {
        return byteRangeToNSRange(start: start, length: length).map { range in
            var lineStart = 0, lineEnd = 0
            getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: range)
            return substring(with: NSRange(location: lineStart, length: NSMaxRange(range) - lineStart))
        }
    }

    /**
    Returns line numbers containing starting and ending byte offsets.

    - parameter start: Starting byte offset.
    - parameter length: Length of bytes to include in range.
    */
    public func lineRangeWithByteRange(start: Int, length: Int) -> (start: Int, end: Int)? {
        return byteRangeToNSRange(start: start, length: length).flatMap { range in
            var numberOfLines = 0, index = 0, lineRangeStart = 0
            while index < self.length {
                numberOfLines += 1
                if index <= range.location {
                    lineRangeStart = numberOfLines
                }
                index = NSMaxRange(lineRange(for: NSRange(location: index, length: 1)))
                if index > NSMaxRange(range) {
                    return (lineRangeStart, numberOfLines)
                }
            }
            return nil
        }
    }

    /**
    Returns an array of Lines for each line in the file.
    */
    public func lines() -> [Line] {
        return cacheContainer.lines
    }

    /**
    Returns true if self is an Objective-C header file.
    */
    public func isObjectiveCHeaderFile() -> Bool {
        return ["h", "hpp", "hh"].contains(pathExtension)
    }

    /**
    Returns true if self is a Swift file.
    */
    public func isSwiftFile() -> Bool {
        return pathExtension == "swift"
    }

#if !os(Linux)
    /**
    Returns a substring from a start and end SourceLocation.
    */
    public func substringWithSourceRange(start: SourceLocation, end: SourceLocation) -> String? {
        return substringWithByteRange(start: Int(start.offset), length: Int(end.offset - start.offset))
    }
#endif
}

extension String {
    internal var isFile: Bool {
        return FileManager.default.fileExists(atPath: self)
    }

    internal func capitalizingFirstLetter() -> String {
        return String(characters.prefix(1)).capitalized + String(characters.dropFirst())
    }

#if !os(Linux)
    /// Returns the `#pragma mark`s in the string.
    /// Just the content; no leading dashes or leading `#pragma mark`.
    public func pragmaMarks(filename: String, excludeRanges: [NSRange], limit: NSRange?) -> [SourceDeclaration] {
        let regex = try! NSRegularExpression(pattern: "(#pragma\\smark|@name)[ -]*([^\\n]+)", options: []) // Safe to force try
        let range: NSRange
        if let limit = limit {
            range = NSRange(location: limit.location, length: min(utf16.count - limit.location, limit.length))
        } else {
            range = NSRange(location: 0, length: utf16.count)
        }
        let matches = regex.matches(in: self, options: [], range: range)

        return matches.flatMap { match in
            let markRange = match.rangeAt(2)
            for excludedRange in excludeRanges {
                if NSIntersectionRange(excludedRange, markRange).length > 0 {
                    return nil
                }
            }
            let markString = (self as NSString).substring(with: markRange).trimmingCharacters(in: .whitespaces)
            if markString.isEmpty {
                return nil
            }
            guard let markByteRange = self.NSRangeToByteRange(start: markRange.location, length: markRange.length) else {
                return nil
            }
            let location = SourceLocation(file: filename,
                line: UInt32((self as NSString).lineRangeWithByteRange(start: markByteRange.location, length: 0)!.start),
                column: 1, offset: UInt32(markByteRange.location))
            return SourceDeclaration(type: .mark, location: location, extent: (location, location), name: markString,
                usr: nil, declaration: nil, documentation: nil, commentBody: nil, children: [], swiftDeclaration: nil, availability: nil)
        }
    }
#endif

    /**
    Returns whether or not the `token` can be documented. Either because it is a
    `SyntaxKind.Identifier` or because it is a function treated as a `SyntaxKind.Keyword`:

    - `subscript`
    - `init`
    - `deinit`

    - parameter token: Token to process.
    */
    public func isTokenDocumentable(token: SyntaxToken) -> Bool {
        if token.type == SyntaxKind.keyword.rawValue {
            let keywordFunctions = ["subscript", "init", "deinit"]
            return bridge().substringWithByteRange(start: token.offset, length: token.length)
                .map(keywordFunctions.contains) ?? false
        }
        return token.type == SyntaxKind.identifier.rawValue
    }

    /**
    Find integer offsets of documented Swift tokens in self.

    - parameter syntaxMap: Syntax Map returned from SourceKit editor.open request.

    - returns: Array of documented token offsets.
    */
    public func documentedTokenOffsets(syntaxMap: SyntaxMap) -> [Int] {
        let documentableOffsets = syntaxMap.tokens.filter(isTokenDocumentable).map {
            $0.offset
        }

        let regex = try! NSRegularExpression(pattern: "(///.*\\n|\\*/\\n)", options: []) // Safe to force try
        let range = NSRange(location: 0, length: utf16.count)
        let matches = regex.matches(in: self, options: [], range: range)

        return matches.flatMap { match in
            documentableOffsets.first { $0 >= match.range.location }
        }
    }

    /**
    Returns the body of the comment if the string is a comment.

    - parameter range: Range to restrict the search for a comment body.
    */
    public func commentBody(range: NSRange? = nil) -> String? {
        let nsString = bridge()
        let patterns: [(pattern: String, options: NSRegularExpression.Options)] = [
            ("^\\s*\\/\\*\\*\\s*(.*?)\\*\\/", [.anchorsMatchLines, .dotMatchesLineSeparators]), // multi: ^\s*\/\*\*\s*(.*?)\*\/
            ("^\\s*\\/\\/\\/(.+)?",           .anchorsMatchLines)                               // single: ^\s*\/\/\/(.+)?
            // swiftlint:disable:previous comma
        ]
        let range = range ?? NSRange(location: 0, length: nsString.length)
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern.pattern, options: pattern.options) // Safe to force try
            let matches = regex.matches(in: self, options: [], range: range)
            let bodyParts = matches.flatMap { match -> [String] in
                let numberOfRanges = match.numberOfRanges
                if numberOfRanges < 1 {
                    return []
                }
                return (1..<numberOfRanges).map { rangeIndex in
                    let range = match.rangeAt(rangeIndex)
                    if range.location == NSNotFound {
                        return "" // empty capture group, return empty string
                    }
                    var lineStart = 0
                    var lineEnd = nsString.length
                    let indexRange = NSRange(location: range.location, length: 0)
                    nsString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: indexRange)
                    let leadingWhitespaceCountToAdd = nsString.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                                                              .countOfLeadingCharacters(in: .whitespacesAndNewlines)
                    let leadingWhitespaceToAdd = String(repeating: " ", count: leadingWhitespaceCountToAdd)

                    let bodySubstring = nsString.substring(with: range)
                    if bodySubstring.contains("@name") {
                        return "" // appledoc directive, return empty string
                    }
                    return leadingWhitespaceToAdd + bodySubstring
                }
            }
            if !bodyParts.isEmpty {
                return bodyParts.joined(separator: "\n").bridge()
                    .trimmingTrailingCharacters(in: .whitespacesAndNewlines)
                    .removingCommonLeadingWhitespaceFromLines()
            }
        }
        return nil
    }

    /// Returns a copy of `self` with the leading whitespace common in each line removed.
    public func removingCommonLeadingWhitespaceFromLines() -> String {
        var minLeadingCharacters = Int.max

        let lineComponents = components(separatedBy: .newlines)

        for line in lineComponents {
            let lineLeadingWhitespace = line.countOfLeadingCharacters(in: .whitespacesAndNewlines)
            let lineLeadingCharacters = line.countOfLeadingCharacters(in: commentLinePrefixCharacterSet)
            // Is this prefix smaller than our last and not entirely whitespace?
            if lineLeadingCharacters < minLeadingCharacters && lineLeadingWhitespace != line.characters.count {
                minLeadingCharacters = lineLeadingCharacters
            }
        }

        return lineComponents.map { line in
            if line.characters.count >= minLeadingCharacters {
                return line[line.index(line.startIndex, offsetBy: minLeadingCharacters)..<line.endIndex]
            }
            return line
        }.joined(separator: "\n")
    }

    /**
    Returns the number of contiguous characters at the start of `self` belonging to `characterSet`.

    - parameter characterSet: Character set to check for membership.
    */
    public func countOfLeadingCharacters(in characterSet: CharacterSet) -> Int {
        let characterSet = characterSet.bridge()
        var count = 0
        for char in utf16 {
            if !characterSet.characterIsMember(char) {
                break
            }
            count += 1
        }
        return count
    }

    /// Returns a copy of the string by trimming whitespace and the opening curly brace (`{`).
    internal func trimmingWhitespaceAndOpeningCurlyBrace() -> String? {
        var unwantedSet = CharacterSet.whitespacesAndNewlines
        unwantedSet.insert(charactersIn: "{")
        return trimmingCharacters(in: unwantedSet)
    }
}

// MARK: - migration support
extension NSString {
    @available(*, unavailable, renamed: "lineAndCharacter(forCharacterOffset:)")
    public func lineAndCharacterForCharacterOffset(_ offset: Int) -> (line: Int, character: Int)? {
        fatalError()
    }

    @available(*, unavailable, renamed: "lineAndCharacter(forByteOffset:)")
    public func lineAndCharacterForByteOffset(_ offset: Int) -> (line: Int, character: Int)? {
        fatalError()
    }

    @available(*, unavailable, renamed: "trimmingTrailingCharacters(in:)")
    public func stringByTrimmingTrailingCharactersInSet(_ characterSet: CharacterSet) -> String {
        fatalError()
    }

    @available(*, unavailable, renamed: "absolutePathRepresentation(rootDirectory:)")
    public func absolutePathRepresentation(_ rootDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        fatalError()
    }

#if !os(Linux)
    @available(*, unavailable, renamed: "substringWithSourceRange(start:end:)")
    public func substringWithSourceRange(_ start: SourceLocation, end: SourceLocation) -> String? {
        fatalError()
    }
#endif
}

extension String {
#if !os(Linux)
    @available(*, unavailable, renamed: "pragmaMarks(_:excludeRanges:limit:)")
    public func pragmaMarks(_ filename: String, excludeRanges: [NSRange], limitRange: NSRange?) -> [SourceDeclaration] {
        fatalError()
    }
#endif

    @available(*, unavailable, renamed: "documentedTokenOffsets(syntaxMap:)")
    public func documentedTokenOffsets(_ syntaxMap: SyntaxMap) -> [Int] {
        fatalError()
    }

    @available(*, unavailable, renamed: "commentBody(range:)")
    public func commentBody(_ range: NSRange? = nil) -> String? {
        fatalError()
    }

    @available(*, unavailable, renamed: "removingCommonLeadingWhitespaceFromLines()")
    public func stringByRemovingCommonLeadingWhitespaceFromLines() -> String {
        fatalError()
    }

    @available(*, unavailable, renamed: "countOfLeadingCharacters(in:)")
    public func countOfLeadingCharactersInSet(_ characterSet: CharacterSet) -> Int {
        fatalError()
    }
}
