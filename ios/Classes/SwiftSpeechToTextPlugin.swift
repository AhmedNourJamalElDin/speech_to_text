import Flutter
import UIKit
import Speech

public enum SwiftSpeechToTextMethods: String {
    case initialize
    case listen
    case stop
    case cancel
    case locales
    case unknown // just for testing
}

public enum SwiftSpeechToTextCallbackMethods: String {
    case textRecognition
    case notifyStatus
    case notifyError
}

public enum SpeechToTextStatus: String {
    case listening
    case notListening
    case unavailable
    case available
}

struct SpeechRecognitionResult : Codable {
    let recognizedWords: String
    let finalResult: Bool
}

public class SwiftSpeechToTextPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var recognizer: AnyObject?
    private var currentRequest: AnyObject?
    private var currentTask: AnyObject?
    private var listeningSound: AVAudioPlayer?
    private var successSound: AVAudioPlayer?
    private var cancelSound: AVAudioPlayer?
    private var rememberedAudioCategory: AVAudioSession.Category?
    private var previousLocale: Locale?
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioEngine = AVAudioEngine()
    private let jsonEncoder = JSONEncoder()
    private let busForNodeTap = 0
    private let speechBufferSize: AVAudioFrameCount = 1024
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "plugin.csdcorp.com/speech_to_text", binaryMessenger: registrar.messenger())
        let instance = SwiftSpeechToTextPlugin( channel, registrar: registrar )
        registrar.addMethodCallDelegate(instance, channel: channel )
    }
    
    init( _ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case SwiftSpeechToTextMethods.initialize.rawValue:
            initialize( result )
        case SwiftSpeechToTextMethods.listen.rawValue:
            if let localeStr = call.arguments as? String  {
                listenForSpeech( result, localeStr: localeStr )
            }
            else {
                listenForSpeech( result, localeStr: nil )
            }
        case SwiftSpeechToTextMethods.stop.rawValue:
            stopSpeech( result )
        case SwiftSpeechToTextMethods.cancel.rawValue:
            cancelSpeech( result )
        case SwiftSpeechToTextMethods.locales.rawValue:
            locales( result )
        default:
            print("Unrecognized method: \(call.method)")
            result( FlutterMethodNotImplemented)
        }
    }
    
    private func initialize( _ result: @escaping FlutterResult) {
        var success = false
        if #available(iOS 10.0, *) {
            if ( SFSpeechRecognizer.authorizationStatus() == SFSpeechRecognizerAuthorizationStatus.notDetermined ) {
                SFSpeechRecognizer.requestAuthorization({(status)->Void in
                    success = status == SFSpeechRecognizerAuthorizationStatus.authorized
                    if ( success ) {
                        self.setupSpeechRecognition(result)
                    }
                    else {
                        self.initResult( false, result );
                    }
                });
            }
            else {
                setupSpeechRecognition(result)
            }
        }
        else {
            self.initResult( false, result );
        }
    }
    
    fileprivate func initResult( _ value: Bool, _ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result( value )
        }
    }
    
    fileprivate func setupListeningSound() {
        listeningSound = loadSound("assets/sounds/speech_to_text_listening.m4r")
        successSound = loadSound("assets/sounds/speech_to_text_stop.m4r")
        cancelSound = loadSound("assets/sounds/speech_to_text_cancel.m4r")
    }
    
    fileprivate func loadSound( _ soundPath: String ) -> AVAudioPlayer? {
        var player: AVAudioPlayer? = nil
        let soundKey = registrar.lookupKey(forAsset: soundPath )
        guard !soundKey.isEmpty else {
            return player
        }
        if let soundPath = Bundle.main.path(forResource: soundKey, ofType:nil) {
            let soundUrl = URL(fileURLWithPath: soundPath )
            do {
                player = try AVAudioPlayer(contentsOf: soundUrl )
            } catch {
                // no audio
            }
        }
        return player
    }
    
    private func setupSpeechRecognition( _ result: @escaping FlutterResult) {
        setupRecognizerForLocale( locale: Locale.current )
        guard recognizer != nil else {
            initResult( false, result );
            return
        }
        if #available(iOS 10.0, *) {
            if let spRecognizer = recognizer as! SFSpeechRecognizer? {
                spRecognizer.delegate = self
            }
            setupListeningSound()
        }
        initResult( true, result );
    }

    private func setupRecognizerForLocale( locale: Locale ) {
        if ( previousLocale == locale ) {
            return
        }
        previousLocale = locale
        if #available(iOS 10.0, *) {
            recognizer = SFSpeechRecognizer( locale: locale )
        }
    }
    
    private func getLocale( _ localeStr: String? ) -> Locale {
        guard let aLocaleStr = localeStr else {
            return Locale.current
        }
        let locale = Locale(identifier: aLocaleStr)
        return locale
    }
    
    private func stopSpeech( _ result: @escaping FlutterResult) {
        if #available(iOS 10.0, *) {
            if let spTask = currentTask as! SFSpeechRecognitionTask? {
                spTask.finish()
            }
        }
        stopCurrentListen( )
        successSound?.play()
        result( true )
    }
    
    private func cancelSpeech( _ result: @escaping FlutterResult) {
        if #available(iOS 10.0, *) {
            if let spTask = currentTask as! SFSpeechRecognitionTask? {
                spTask.cancel()
            }
        }
        stopCurrentListen( )
        cancelSound?.play()
        result( true )
    }
    
    private func stopCurrentListen( ) {
        currentRequest?.endAudio()
        audioEngine.stop()
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: busForNodeTap);
        do {
            if let rememberedAudioCategory = rememberedAudioCategory {
                try self.audioSession.setCategory(rememberedAudioCategory)
            }
        }
        catch {
        }
        currentRequest = nil
        currentTask = nil
    }
    
    private func listenForSpeech( _ result: @escaping FlutterResult, localeStr: String? ) {
        if ( nil != currentTask ) {
            return
        }
        if #available(iOS 10.0, *) {
            do {
                setupRecognizerForLocale(locale: getLocale(localeStr))
                listeningSound?.play()
                rememberedAudioCategory = self.audioSession.category
                try self.audioSession.setCategory(AVAudioSession.Category.playAndRecord)
                try self.audioSession.setMode(AVAudioSession.Mode.measurement)
                try self.audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                let inputNode = self.audioEngine.inputNode
                self.currentRequest = SFSpeechAudioBufferRecognitionRequest()
                guard let currentRequest = self.currentRequest else {
                    result( false )
                    return
                }
                if let spRequest = self.currentRequest as! SFSpeechRecognitionRequest? {
                    spRequest.shouldReportPartialResults = true
                    self.currentTask = self.recognizer?.recognitionTask(with: spRequest, delegate: self )
                }
                let recordingFormat = inputNode.outputFormat(forBus: self.busForNodeTap)
                inputNode.installTap(onBus: self.busForNodeTap, bufferSize: self.speechBufferSize, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                    currentRequest.append(buffer)
                }
                
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.listening.rawValue )
            }
            catch {
                result( false )
            }
        }
    }
    
    /// Build a list of localId:name with the current locale first
    private func locales( _ result: @escaping FlutterResult ) {
        var localeNames = [String]();
        if #available(iOS 10.0, *) {
            let locales = SFSpeechRecognizer.supportedLocales();
            let currentLocale = Locale.current
            if let idName = buildIdNameForLocale(forIdentifier: currentLocale.identifier ) {
                localeNames.append(idName)
            }
            for locale in locales {
                if ( locale.identifier == currentLocale.identifier) {
                    continue
                }
                if let idName = buildIdNameForLocale(forIdentifier: locale.identifier ) {
                    localeNames.append(idName)
                }
            }
        }
        result(localeNames)
    }
    
    private func buildIdNameForLocale( forIdentifier: String ) -> String? {
        var idName: String?
        if let name = Locale.current.localizedString(forIdentifier: forIdentifier ) {
            let sanitizedName = name.replacingOccurrences(of: ":", with: " ")
            idName = "\(forIdentifier):\(sanitizedName)"
        }
        return idName
    }
    
    private func handleResult( _ recognizedWords: String, isFinal: Bool ) {
        let speechInfo = SpeechRecognitionResult(recognizedWords: recognizedWords, finalResult: isFinal )
        do {
            let speechMsg = try jsonEncoder.encode(speechInfo)
            invokeFlutter( SwiftSpeechToTextCallbackMethods.textRecognition, arguments: String( data:speechMsg, encoding: .utf8) )
        } catch {
            print("Could not encode JSON")
        }
    }
    
    private func invokeFlutter( _ method: SwiftSpeechToTextCallbackMethods, arguments: Any? ) {
        DispatchQueue.main.async {
            self.channel.invokeMethod( method.rawValue, arguments: arguments )
        }
    }
        
}

@available(iOS 10.0, *)
extension SwiftSpeechToTextPlugin : SFSpeechRecognizerDelegate {
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        let availability = available ? SpeechToTextStatus.available : SpeechToTextStatus.unavailable
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: availability )
    }
}

@available(iOS 10.0, *)
extension SwiftSpeechToTextPlugin : SFSpeechRecognitionTaskDelegate {
    public func speechRecognitionDidDetectSpeech(_ task: SFSpeechRecognitionTask) {
        // Do nothing for now
    }
    
    public func speechRecognitionTaskFinishedReadingAudio(_ task: SFSpeechRecognitionTask) {
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue )
    }
    
    public func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        invokeFlutter( SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        stopCurrentListen( )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        handleResult( transcription.formattedString, isFinal: false )
    }
    
    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        let isFinal = recognitionResult.isFinal
        handleResult( recognitionResult.bestTranscription.formattedString, isFinal: isFinal )
    }
    
}

@available(iOS 8.0, *)
extension SwiftSpeechToTextPlugin : AVAudioPlayerDelegate {
    
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                     successfully flag: Bool) {
        
    }
}
