//
//  KVEventSourceMessageParser.swift
//  SSCClient
//
//  Created by tumlw on 19/07/2022.
//  Copyright © 2022 Citigo. All rights reserved.
//

import Foundation

final class KVEventSourceMessageParse {
    
    //  Events are separated by end of line. End of line can be:
    //  \r = CR (Carriage Return) → Used as a new line character in Mac OS before X
    //  \n = LF (Line Feed) → Used as a new line character in Unix/Mac OS X
    //  \r\n = CR + LF → Used as a new line character in Windows
    private let validNewLineCharacters = ["\r\n", "\n", "\r"]
    private let dataBuffer: NSMutableData
    
    init() {
        dataBuffer = NSMutableData()
    }
    
    var currentBuffer: String? {
        return NSString(data: dataBuffer as Data, encoding: String.Encoding.utf8.rawValue) as String?
    }
    
    func appendData(_ data: Data?) -> [KVEvent] {
        guard let data = data else {
            return []
        }
        
        dataBuffer.append(data)
        let events = extractEventsFromBuffer().compactMap { [weak self] eventString -> KVEvent? in
            guard let self = self else {
                return nil
            }
            return KVEvent(eventString: eventString, newLineCharacters: self.validNewLineCharacters)
        }
        return events
    }
    
    private func extractEventsFromBuffer() -> [String] {
        var events = [String]()
        
        var searchRange = NSRange(location: 0, length: dataBuffer.length)
        
        while let foundRange = searchFirstEventDelimeter(in: searchRange) {
            // tìm kiếm khoảng cách mà khi bắt đầu buffer tới khi kết thúc range finder: tìm thấy được event
            // bắt đầu của 1 event có format: searchRange.location
            // khoảng cách của event là từ vị trí foundRange được tìm thấy
            
            // if we found a delimiter range that means that from the beggining of the buffer
            // until the beggining of the range where the delimiter was found we have an event.
            // The beggining of the event is: searchRange.location
            // The lenght of the event is the position where the foundRange was found.
            let dataChunk = dataBuffer.subdata(with: NSRange(location: searchRange.location, length: foundRange.location - searchRange.location))
            
            if let text = String(bytes: dataChunk, encoding: .utf8) {
                events.append(text)
            }
                                 
            // We move the searchRange start position (location) after the fundRange we just found and
            searchRange.location = foundRange.location + foundRange.length
            searchRange.length = dataBuffer.length - searchRange.location
        }
        
        // We empty the piece of the buffer we just search in.
        dataBuffer.replaceBytes(in: NSRange(location: 0, length: searchRange.location), withBytes: nil, length: 0)
        
        return events
    }
     
    private func searchFirstEventDelimeter(in range: NSRange) -> NSRange? {
        let delimiters = validNewLineCharacters.map { "\($0)\($0)".data(using: String.Encoding.utf8)! }

        for delimiter in delimiters {
            let foundRange = dataBuffer.range(
                of: delimiter, options: NSData.SearchOptions(), in: range
            )
            
            if foundRange.location != NSNotFound {
                return foundRange
            }
        }

        return nil
     }
}
