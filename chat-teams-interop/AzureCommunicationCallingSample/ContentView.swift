// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

import SwiftUI
import AzureCommunicationCalling
import AzureCommunicationChat
import AVFoundation

struct ContentView: View {
    // Calling
    @State var meetingLink: String = ""
    @State var status: String = ""
    @State var message: String = ""
    @State var recordingStatus: String = ""
    @State var callClient: CallClient?
    @State var callAgent: CallAgent?
    @State var call: Call?
    @State var callObserver: CallObserver?

    // Chat
    @State var chatClient: ChatClient?
    @State var chatThreadClient: ChatThreadClient?
    @State var chatMessage: String = ""
    @State var meetingMessages: [MeetingMessage] = []

    let displayName: String = "<YOUR_DISPLAY_NAME_HERE>"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Teams meeting link", text: $meetingLink)
                    Button(action: joinTeamsMeeting) {
                        Text("Join Teams Meeting")
                    }.disabled(callAgent == nil)
                    Button(action: leaveMeeting) {
                        Text("Leave Meeting")
                    }.disabled(call == nil)
                    Text(status)
                    Text(message)
                    Text(recordingStatus)
                    VStack(alignment: .leading) {
                        ForEach(meetingMessages, id: \.id) { message in
                            let currentUser: Bool = (message.displayName == self.displayName)
                            let foregroundColor = currentUser ? Color.white : Color.black
                            let background = currentUser ? Color.blue : Color(.systemGray6)
                            let alignment = currentUser ? HorizontalAlignment.trailing : HorizontalAlignment.leading
                            VStack {
                                Text(message.displayName).font(Font.system(size: 10))
                                Text(message.content)
                            }
                            .alignmentGuide(.leading) { d in d[alignment] }
                            .padding(10)
                            .foregroundColor(foregroundColor)
                            .background(background)
                            .cornerRadius(10)
                        }
                    }.frame(minWidth: 0, maxWidth: .infinity)
                    TextField("Enter your message...", text: $chatMessage)
                    Button(action: sendMessage) {
                        Text("Send Message")
                    }.disabled(chatThreadClient == nil)
                }
            }
            .navigationBarTitle("Chat Teams Quickstart")
        }.onAppear {
            // Initialize call agent
            var userCredential: CommunicationTokenCredential?
            do {
                userCredential = try CommunicationTokenCredential(token: "<USER_ACCESS_TOKEN_HERE>")
            } catch {
                print("ERROR: It was not possible to create user credential.")
                self.message = "Please enter your token in source code"
                return
            }

            self.callClient = CallClient()

            // Creates the call agent
            self.callClient?.createCallAgent(userCredential: userCredential!) { (agent, error) in
                if error != nil {
                    print("ERROR: It was not possible to create a call agent.")
                    return
                }
                else {
                    self.callAgent = agent
                    self.message = "Call agent successfully created."
                }
            }

            // Initialize the ChatClient
            do {
                let endpoint = "<ACS_RESOURCE_ENDPOINT_HERE>"
                let credential = try CommunicationTokenCredential(token: "<USER_ACCESS_TOKEN_HERE>")

                self.chatClient = try ChatClient(
                    endpoint: endpoint,
                    credential: credential,
                    withOptions: AzureCommunicationChatClientOptions()
                )

                self.message = "ChatClient successfully created"

                // Start realtime notifications
                self.chatClient?.startRealTimeNotifications() { result in
                    switch result {
                    case .success:
                        print("Realtime notifications started")
                        // Receive chat messages
                        self.chatClient?.register(event: ChatEventId.chatMessageReceived, handler: receiveMessage)
                    case .failure:
                        print("Failed to start realtime notifications")
                        self.message = "Failed to enable chat notifications"
                    }
                }
            } catch {
                print("Unable to create ChatClient")
                self.message = "Please enter a valid endpoint and Chat token in source code"
                return
            }
        }
    }
    
    func joinTeamsMeeting() {
        // Ask permissions
        AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
            if granted {
                let joinCallOptions = JoinCallOptions()
                let teamsMeetingLinkLocator = TeamsMeetingLinkLocator(meetingLink: self.meetingLink);

                self.callAgent?.join(with: teamsMeetingLinkLocator, joinCallOptions: joinCallOptions) { (call, error) in
                    if (error == nil) {
                        self.call = call
                        self.callObserver = CallObserver(self)
                        self.call!.delegate = self.callObserver
                        self.message = "Teams meeting joined successfully"

                        // Initialize the ChatThreadClient
                        do {
                            guard let threadId = getThreadId(from: self.meetingLink) else {
                                self.message = "Failed to join meeting chat"
                                return
                            }
                            self.chatThreadClient = try chatClient?.createClient(forThread: threadId)
                            self.message = "Joined meeting chat successfully"
                        } catch {
                            print("Failed to create ChatThreadClient")
                            self.message = "Failed to join meeting chat"
                            return
                        }
                    } else {
                        print("Failed to join Teams meeting")
                    }
                }
            }
        }
    }

    func leaveMeeting() {
        if let call = call {
            call.hangUp(options: nil, completionHandler: { (error) in
                if error == nil {
                    self.message = "Leaving Teams meeting was successful"
                    self.meetingMessages.removeAll()
                } else {
                    self.message = "Leaving Teams meeting failed"
                }
            })
        } else {
            self.message = "No active call to hanup"
        }
    }
    
    func sendMessage() {
        let message = SendChatMessageRequest(
            content: self.chatMessage,
            senderDisplayName: self.displayName
        )
        
        self.chatThreadClient?.send(message: message) { result, _ in
            switch result {
            case .success:
                print("Chat message sent")
            case .failure:
                print("Failed to send chat message")
            }

            self.chatMessage = ""
        }
    }

    func receiveMessage(response: Any, eventId: ChatEventId) {
        let chatEvent: ChatMessageReceivedEvent = response as! ChatMessageReceivedEvent

        let displayName: String = chatEvent.senderDisplayName ?? "Unknown User"
        let content: String = chatEvent.message.replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression)

        self.meetingMessages.append(
            MeetingMessage(
                id: chatEvent.id,
                content: content,
                displayName: displayName
            )
        )
    }

    func getThreadId(from meetingLink: String) -> String? {
        if let range = self.meetingLink.range(of: "meetup-join/") {
            let thread = self.meetingLink[range.upperBound...]
            if let endRange = thread.range(of: "/")?.lowerBound {
                return String(thread.prefix(upTo: endRange))
            }
        }
        return nil
    }
}

class CallObserver : NSObject, CallDelegate {
    private var owner:ContentView
    init(_ view:ContentView) {
        owner = view
    }

    public func onCallStateChanged(_ call: Call!,
                                   args: PropertyChangedEventArgs!) {
        owner.status = CallObserver.callStateToString(state: call.state)
        if call.state == .disconnected {
            owner.call = nil
            owner.message = "Call ended"
        } else if call.state == .connected {
            owner.message = "Call connected !!"
        }
    }

    private static func callStateToString(state: CallState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        case .disconnecting: return "Disconnecting"
        case .earlyMedia: return "EarlyMedia"
        case .none: return "None"
        case .ringing: return "Ringing"
        default: return "Unknown"
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct MeetingMessage {
    let id: String
    let content: String
    let displayName: String
}
