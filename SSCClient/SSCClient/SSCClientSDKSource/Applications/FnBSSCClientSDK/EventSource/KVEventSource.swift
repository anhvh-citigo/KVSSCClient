//
//  KVEventSource.swift
//  SSCClient
//
//  Created by tumlw on 19/07/2022.
//  Copyright © 2022 Citigo. All rights reserved.
//

import Foundation

public enum KVEventSourceState {
    case connecting
    case open
    case closed
}

public protocol KVEventSourceProtocol {
    var headers: [String:String] { get }
    
    /// retry time: able changed if server send event `retry:`
    var retryTime: Int { get }
    
    /// URL where eventSource will listen
    var url: URL { get }
    
    /// Last Event Id : the last event id received from server. This is needed to keep track of the last event-id received to avoid receiving duplica events after reconnection
    var lastEventId: String? { get }
    
    /// Current state of eventSource
    var readyState: KVEventSourceState { get }
    
    /// Method used to connect to server.
    /// Able to received lastEventId
    /// - Parameter lastEventId: optional value that is going to be added on the request header to server.
    func connect(lastEventId: String?)
    
    /// Method used to disconnect from server
    func disconnect()
    
    /// Returns the list of event names that we are currently listening for.
    ///
    /// - Returns: List of event names.
    func events() -> [String]
    
    /// Callback called when EventSource has successfully connected to the server.
    ///
    /// - Parameter onOpenCallback: callback
    func onOpen(_ onOpenCallback: @escaping (() -> Void))
    
    /// Callback called once EventSource has disconnected from server. This can happen for multiple reasons.
    /// The server could have requested the disconnection or maybe a network layer error, wrong URL or any other
    /// error. The callback receives as parameters the status code of the disconnection, if we should reconnect or not
    /// following event source rules and finally the network layer error if any. All this information is more than
    /// enought for you to take a decition if you should reconnect or not.
    /// - Parameter onOpenCallback: callback
    func onComplete(_ onComplete: @escaping ((Int?, Bool?, NSError?) -> Void))
    
    /// This callback is called everytime an event with name "message" or no name is received.
    func onMessage(_ onMessageCallback: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void))
    
    /// Add an event handler for an specific event name.
    ///
    /// - Parameters:
    ///   - event: name of the event to receive
    ///   - handler: this handler will be called everytime an event is received with this event-name
    func addEventListener(_ event: String,
                          handler: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void))
    
    /// Remove an event handler for the event-name
    ///
    /// - Parameter event: name of the listener to be remove from event source.
    func removeEventListener(_ event: String)
}


open class KVEventSource : NSObject, KVEventSourceProtocol, URLSessionDataDelegate {
    static let defaultRetryTime = 3000
    
    public let url: URL
    private(set) public var lastEventId: String?
    private(set) public var retryTime = KVEventSource.defaultRetryTime
    private(set) public var headers: [String : String]
    private(set) public var readyState: KVEventSourceState
    
    private var onOpenCallback: (() -> Void)?
    private var onComplete: ((Int?, Bool?, NSError?) -> Void)?
    private var onMessageCallback: ((_ id: String?, _ event: String?, _ data: String?) -> Void)?
    private var eventListeners: [String: (_ id: String?, _ event: String?, _ data: String?) -> Void] = [:]
    
    private var eventMessageParser = KVEventSourceMessageParse?
    private var operationQueue: OperationQueue
    private var mainQueue = DispatchQueue.main
    private var urlSession: URLSession?
    
    public init(url: URL, headers: [String : String] = [:]) {
        self.url = url
        self.headers = headers
        
        readyState = KVEventSourceState.closed
        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        
        super.init()
    }
    
    public func connect(lastEventId: String? = nil) {
        eventMessageParser = KVEventSourceMessageParse()
        readyState = .connecting
        
        let configuration = sessionConfiguration(lastEventId: lastEventId)
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        urlSession?.dataTask(with: url).resume()
    }
    
    public func disconnect() {
        readyState = .closed
        urlSession?.invalidateAndCancel()
    }
    
    public func onOpen(_ onOpenCallback: @escaping (() -> Void)) {
        self.onOpenCallback = onOpenCallback
    }
    
    public func onComplete(_ onComplete: @escaping ((Int?, Bool?, NSError?) -> Void)) {
        self.onComplete = onComplete
    }
    
    public func onMessage(_ onMessageCallback: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)) {
        self.onMessageCallback = onMessageCallback
    }
    
    public func addEventListener(_ event: String,
                                 handler: @escaping ((_ id: String?, _ event: String?, _ data: String?) -> Void)) {
        eventListeners[event] = handler
    }
    
    public func removeEventListener(_ event: String) {
        eventListeners.removeValue(forKey: event)
    }
    
    public func events() -> [String] {
        return Array(eventListeners.keys)
    }
    
    open func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        
        if readyState != .open {
            return
        }
        
        if let events = eventMessageParser?.appendData(data) {
            notifyReceivedEvents(events)
        }
    }
    
    open func urlSession(_ session: URLSession,
                         dataTask: URLSessionDataTask,
                         didReceive response: URLResponse,
                         completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        completionHandler(URLSession.ResponseDisposition.allow)
        
        readyState = .open
        mainQueue.async { [weak self] in self?.onOpenCallback?() }
    }
    
    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         didCompleteWithError error: Error?) {
        
        guard let responseStatusCode = (task.response as? HTTPURLResponse)?.statusCode else {
            mainQueue.async { [weak self] in self?.onComplete?(nil, nil, error as NSError?) }
            return
        }
        
        let reconnect = shouldReconnect(statusCode: responseStatusCode)
        mainQueue.async { [weak self] in self?.onComplete?(responseStatusCode, reconnect, nil) }
    }
    
    open func urlSession(_ session: URLSession,
                         task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest,
                         completionHandler: @escaping (URLRequest?) -> Void) {
        
        var newRequest = request
        self.headers.forEach { newRequest.setValue($1, forHTTPHeaderField: $0) }
        completionHandler(newRequest)
    }
}

internal extension KVEventSource {

    func sessionConfiguration(lastEventId: String?) -> URLSessionConfiguration {

        var additionalHeaders = headers
        if let eventID = lastEventId {
            additionalHeaders["Last-Event-Id"] = eventID
        }

        additionalHeaders["Accept"] = "text/event-stream"
        additionalHeaders["Cache-Control"] = "no-cache"

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = TimeInterval(INT_MAX)
        sessionConfiguration.timeoutIntervalForResource = TimeInterval(INT_MAX)
        sessionConfiguration.httpAdditionalHeaders = additionalHeaders

        return sessionConfiguration
    }

    func readyStateOpen() {
        readyState = .open
    }
}

private extension KVEventSource {

    func notifyReceivedEvents(_ events: [KVEvent]) {

        for event in events {
            lastEventId = event.id
            retryTime = event.retryTime ?? KVEventSource.defaultRetryTime

            if event.onlyRetryEvent == true {
                continue
            }

            if event.event == nil || event.event == "message" {
                mainQueue.async { [weak self] in self?.onMessageCallback?(event.id, "message", event.data) }
            }

            if let eventName = event.event, let eventHandler = eventListeners[eventName] {
                mainQueue.async { eventHandler(event.id, event.event, event.data) }
            }
        }
    }

    // Following "5 Processing model" from:
    // https://www.w3.org/TR/2009/WD-eventsource-20090421/#handler-eventsource-onerror
    func shouldReconnect(statusCode: Int) -> Bool {
        switch statusCode {
        case 200:
            return false
        case _ where statusCode > 200 && statusCode < 300:
            return true
        default:
            return false
        }
    }
}
