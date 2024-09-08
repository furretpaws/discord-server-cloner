import haxe.EntryPoint;
import haxe.Timer;
import haxe.Json;
import hx.ws.Types.MessageType;
import hx.ws.WebSocket;
import Console;

using StringTools;

class DiscordSocket {
	public var token:String = "";
	public var uri:String = "gateway.discord.gg";
	public var ws:WebSocket;
	public var session_id:String = "";
	public var seq:Int = -1;
	public var heartbeat_interval = 0;
	public var heartbeat_timer:Timer = null;

	public function new(_token:String) {
		this.token = _token;
	}

	// Event hook
	dynamic public function onEvent(event:String, json:Dynamic) {}

	public function start() {
		// This function should re-call itself once the connection dies
		sys.thread.Thread.create(() -> {
			ws = new WebSocket('wss://${uri}');
			ws.onopen = function() {}
			ws.onmessage = function(message:MessageType) {
				switch (message) {
					case BytesMessage(content):
						// Don't handle this
					case StrMessage(content):
						var json:Dynamic = Json.parse(content);
						switch (json.op) {
							case 11: // Heartbeat ACK
								// This doesn't need to be handled
							case 10: // Hello
								// Here is where we send the identify payload, this can depend if there's a new connection or a resumed connection
								this.heartbeat_interval = json.d.heartbeat_interval;
								if (this.heartbeat_timer == null) {
									EntryPoint.runInMainThread(() -> {
										this.heartbeat_timer = new Timer(this.heartbeat_interval);
										this.heartbeat_timer.run = () -> {
											var d:Dynamic = null;
											if (seq != -1) {
												d = this.seq;
											}
											ws.send(haxe.Json.stringify({
												op: 1,
												d: d
											}));
										};
									});
									// As Haxe timers do not run the action after spawning a timer, we will have to manually send the heartbeat ourselves
									ws.send(haxe.Json.stringify({
										op: 1,
										d: this.seq
									}));
								}
								ws.send(generateHelloPayload());
							case 9: // Invalid session
								if (json.d) {
									Console.warn("Got an invalid session, API requests reconnection");
									ws.close();
								} else {
									throw "Invalid session. Check your tokens.";
								}
							case 7: // Reconnect
								Console.warn("Client needs to reconnect.");
								ws.close();
							case 0: // Dispatch
								this.seq = json.s;
								switch (json.t) {
									case "READY":
										Console.debug("CLIENT READY, User: " + json.d.user.username);
										this.session_id = json.d.session_id;
										this.uri = json.d.resume_gateway_url.split("wss://")[1];
										Main.logger_id = json.d.user.id;
								}
								onEvent(json.t, json.d);
						}
				}
				ws.onclose = function() {
					this.heartbeat_timer.stop();
					this.heartbeat_timer = null;
					start();
				}
			}
		});
	}

	public function generateHelloPayload():String {
		var resume:Bool = false;
		var payload:String = "";
		if (session_id == "") {
			payload = Json.stringify({
				op: 2,
				d: {
					token: this.token,
					intents: 3276799,
					properties: {
						os: "Linux",
						browser: "Firefox",
						device: "PC"
					}
				}
			});
		} else {
			resume = true;
			payload = Json.stringify({
				op: 6,
				d: {
					token: this.token,
					session_id: this.session_id,
					seq: this.seq
				}
			});
		}
		if (resume) {
			Console.debug("Generating a RESUME payload");
		} else {
			Console.debug("Generating a IDENTIFY payload");
		}
		return payload;
	}
}
