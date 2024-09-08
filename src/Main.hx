import haxe.io.BytesOutput;
import haxe.Int64;
import haxe.Json;
import haxe.Http;
import sys.io.File;
import haxe.io.Bytes;
import sys.FileSystem;
import haxe.MainLoop;

using StringTools;

class Main {
	static var cloner_data:Dynamic;
	static var logging:Bool = false;
	static var started:Bool = false;
	public static var logger_id:String = "";

	static function generateMessageJson(data:Dynamic):Dynamic {
		var json:Dynamic = null;
		if (data.referenced_message != null) {
			var repliedContent:String = "No message";
			if (data.referenced_message.content != null) {
				repliedContent = data.referenced_message.content;
			}
			json = {
				"embeds": [
					{
						"description": '***:speech_balloon:  Replying to ${data.referenced_message.author.global_name}***\n> ↳ ${repliedContent}'
					}
				],
				avatar_url: getFormattedAvatarUrl(data.author),
				content: data.content,
				username: data.author.username,
				allowed_mentions: {parse: []}
			}
		} else {
			json = {
				avatar_url: getFormattedAvatarUrl(data.author),
				content: data.content,
				username: data.author.username,
				allowed_mentions: {parse: []}
			}
		}
		return json;
	}

	static function getFormattedAvatarUrl(data:Dynamic):String {
		if (data.avatar.substring(0, 2) == "a_") { // Bro has Nitro definitely
			data.avatar = data.avatar.split("a_")[1]; // Remove the animated append
		}
		return 'https://cdn.discordapp.com/avatars/${data.id}/${data.avatar}.png?size=1024';
	}

	static function downloadFile(url:String) {
		Console.log("Downloading file " + url);
		var bytes:Bytes = null;
        var http:Http = new Http(url);
		http.onBytes = (b:Bytes) -> {
			bytes = b;
		}
		http.request(false);
        return bytes;
    }

	static function sendMessageToWebhook(data:Dynamic, webhook:String) {
		/**
			This part gets a little bit messy.
			If the user sent some attachments, we need to send them as well and forward them to the webhooks. To send a file on Discord, you need to send a multipart.
			We need to check if there are any attachments present on the message. If so, we would most likely have to make this a multipart request, otherwise, keep it the traditional application/json request.
		**/

		// This code is going to be a fucking mess I bet

		var http:Http = new Http(webhook);
		if (data.attachments.length > 0) {
			// TODO
			var bytes:Array<Bytes> = [];
			var filenames:Array<String> = [];
			for (i in 0...data.attachments.length) {
				bytes.push(downloadFile(data.attachments[i].url));
				filenames.push(data.attachments[i].filename);
			}
			http.addHeader("Content-Type", "multipart/form-data; boundary=boundary");
			var BO:BytesOutput = new BytesOutput();
			BO.writeString("--boundary\n");
			BO.writeString("Content-Disposition: form-data; name=\"payload_json\"\n");
			BO.writeString("Content-Type: application-json");
			BO.writeString("\n\n");
			BO.writeString(Json.stringify(generateMessageJson(data)));
			var attachments:Array<Dynamic> = [];
			for (i in 0...filenames.length) {
				attachments.push({filename: filenames[i], id: i});
			}
			for (i in 0...data.attachments.length) {
				BO.writeString('\n--boundary\n');
				BO.writeString('Content-Disposition: form-data; name="files[' + i + ']"; filename="' + data.attachments[i].filename + '"' + "\n");
				BO.writeString('Content-Type: ' + MimeResolver.getMimeType(data.attachments[i].filename)); //idk why's base64 there but it works so i'm leaving it like that
				BO.writeString("\n\n");
				BO.writeFullBytes(bytes[i], 0, bytes[i].length);
				BO.writeString("\n");
			}
			BO.writeString('--boundary--');
			http.setPostBytes(BO.getBytes());
		} else {
			http.addHeader("Content-Type", "application/json");
			http.setPostData(Json.stringify(generateMessageJson(data)));
		}
		http.request(true);
	}

	static function redirectMessage(d:Dynamic) {
		/**
			This function should look to the matching destination channel, find the webhook and forward the message there.
			If the channel, could not be found for whatever reason, it should generate a new channel on the destination server and append a new webhook to it.
		**/

		// Find the matching destination channel

		var channel_id:String = d.channel_id;
		for (i in 0...cloner_data.channels.length) {
			var channel:Dynamic = cloner_data.channels[i];
			if (channel_id == channel.target_channel_id) {
				sendMessageToWebhook(d, channel.webhook);
			}
		}
	}

	static function main() {
		var config:Dynamic = null;
		if (!FileSystem.exists("userdata.json")) {
			File.saveContent("userdata.json", haxe.Json.stringify({
				tokens: {
					bottoken: "Paste your Discord bot token here",
					usertoken: "Paste your Discord user token here"
				},
				servers: {
					target: "Paste the server ID you want to clone",
					destination: "Paste the server where the server will be cloned"
				},
				authorized_users: [""]
			}, "\t"));
			throw "User data does not exist, check userdata.json.\nMake sure your Discord bot has all special intents enabled.\n\nQuick explanation about the values you need to change:\n- usertoken: This is the token of the user that will be used to log all the channels (cloning the server) and logging all the messages sent.\n- bottoken: This is the token of the bot that will generate all channels and webhooks\n- target: This will be the ID of the server to clone.\n- destination: This will be the ID of the server where the target server will be cloned in.";
		} else {
			config = haxe.Json.parse(File.getContent("userdata.json"));
		}

		function tick() {}
		MainLoop.add(tick);
		var bot_socket:DiscordSocket = new DiscordSocket(config.tokens.bottoken);
		bot_socket.onEvent = (e, d) -> {
			switch (e) {
				case "READY":
					Console.log('<red>[Cloner]</> <white>Connected to the Discord bot</>');
				case "MESSAGE_CREATE":
					if (d.guild_id == config.servers.destination && config.authorized_users.contains(d.author.id)) {
						switch (d.content) {
							case "log!status":
								var response:String = "";
								if (logging == false) {
									response = "The bot is currently not logging any messages.";
								} else {
									response = "The bot is currently logging messages.";
								}
								if (cloner_data != null) {
									response += "\nTargetted server: " + cloner_data.server_details.name;
								}

								var sendResponse:Http = new Http("https://discord.com/api/v9/channels/" + d.channel_id + "/messages");
								sendResponse.addHeader("Authorization", 'Bot ${config.tokens.bottoken}');
								sendResponse.addHeader("Content-Type", "application/json");
								sendResponse.setPostData(haxe.Json.stringify({
									content: response
								}));
								sendResponse.request(true);
						}
					}
			}
		};
		bot_socket.start();

		var user_socket:DiscordSocket = new DiscordSocket(config.tokens.usertoken);
		user_socket.onEvent = (e, d) -> {
			switch (e) {
				case "READY":
					Console.log('<red>[Cloner]</> <white>Connected to the logging account</>');

					/*
						There are sometimes where you cannot resume a session, meaning that your only option is to establish a new Discord session.
						If this is the case and the gateway replies with READY, all of code below will get executed twice, this is something we do not want
						This can be easily prevented by checking if the code has already been executed, through a "started" variable
					 */

					if (!started) {
						// Once the logging account is ready, we can proceed.
						if (!FileSystem.exists("clonerdata.json")) {
							// Looks like the cloner has never been initialized before.
							Console.log('<red>[Cloner]</> <white>Getting data about the guild "${config.servers.target}"</>');

							var generated_data:Dynamic = {
								server_details: null,
								channels: null,
								destination_data: null
							};

							var url = "https://discord.com/api/v10/guilds/" + config.servers.target;
							var http = new Http(url);
							http.addHeader("Authorization", config.tokens.usertoken);

							http.onData = function(data:String) {
								var json:Dynamic = Json.parse(data);
								Console.log('<red>[Cloner]</> <white>Server details:\n- Server name: ${json.name}\n- Server ID: ${json.id}\n- Owner ID: ${json.owner_id}</>');
								Reflect.setField(generated_data, "server_details", {
									name: json.name,
									id: json.id,
									owner_id: json.owner_id
								});
							};

							http.onError = function(error:String) {
								throw "Error "
									+ error
									+
									" while getting the target server information. The user that's cloning the server might've not joined the server or the server does not exist.\nError: "
									+ http.responseData;
							};

							http.request(false);

							if (generated_data.server_details != null) { // stupid check
								Console.log('<red>[Cloner]</> <white>Getting logger roles for ${generated_data.server_details.name}</>');
								var roles:Array<Dynamic> = [];

								var url = "https://discord.com/api/v10/guilds/" + config.servers.target + "/members/" + logger_id;
								var http = new Http(url);
								http.addHeader("Authorization", config.tokens.usertoken);

								http.onData = function(data:String) {
									roles = Json.parse(data).roles;
								};

								http.onError = function(error:String) {
									throw "Error "
										+ error
										+
										" while getting the target server information. The user that's cloning the server might've not joined the server or the server does not exist.\nError: "
										+ http.responseData;
								};

								http.request(false);


								Console.log('<red>[Cloner]</> <white>Getting channels for ${generated_data.server_details.name}</>');
								var url = "https://discord.com/api/v10/guilds/" + config.servers.target + "/channels";
								var server_data:Dynamic = null;
								var http = new Http(url);
								http.addHeader("Authorization", config.tokens.usertoken);

								http.onData = function(data:String) {
									server_data = Json.parse(data);
									// trace(server_data);
								};

								http.onError = function(error:String) {
									throw "Error "
										+ error
										+
										" while getting the target server channels. The user that's cloning the server might've not joined the server or the server does not exist.\nError: "
										+ http.responseData;
								};

								http.request(false);

								Console.log('<red>[Cloner]</> <white>Generating channels on destination server</>');
								Console.log('<red>[Cloner]</> <white>1. Creating server category</>');

								var parent_id_category:String = null;

								var url = "https://discord.com/api/v9/guilds/" + config.servers.destination + "/channels";

								var http = new Http(url);
								http.addHeader("Authorization", "Bot " + config.tokens.bottoken);
								http.addHeader("Content-Type", "application/json");
								http.setPostData(haxe.Json.stringify({
									type: 4,
									name: generated_data.server_details.name,
									permissions_overwrites: []
								}));

								http.onData = (data:String) -> {
									var js:Dynamic = Json.parse(data);
									parent_id_category = js.id;
								};

								http.onError = function(error:String) {
									throw "Error " + error + " while creating the server channels\nError: " + http.responseData;
								};

								http.request(true);

								Reflect.setField(generated_data, "destination_data", {
									parent_id: parent_id_category
								});

								var channels_data:Array<Dynamic> = [];

								Console.log('<red>[Cloner]</> <white>2. Creating channels on the new category</>');

								for (i in 0...server_data.length) {
									// Should generate a new channel and a new webhook for said channel

									/**
										There has to be a check whether if the user can see this channel or not, if not, do not create it.
										If the category has reached 50 channels, just, stop generating and start logging, leave the other channels untouched
									**/
									var target_channel:Dynamic = server_data[i];
									if (target_channel.type == 0) {
										Console.log('<red>[Cloner]</> <white>Creating channel for ${target_channel.name}</>');

										var canSeeChannel:Bool = true;

										var permission_overwrites:Array<Dynamic> = target_channel.permission_overwrites;
										for (thing in permission_overwrites) {
											if (roles.contains(thing.id)) {
												var deniedPermissions:Array<String> = Permissions.resolve(Int64.fromFloat(Std.parseFloat(thing.deny)));
												if (deniedPermissions.contains("VIEW_CHANNEL")) {
													canSeeChannel = false;
												}
											}
										}

										if (canSeeChannel) {
											var destination_channel_id:String = null;
											var webhook:String = null;

											var url = "https://discord.com/api/v9/guilds/" + config.servers.destination + "/channels";

											var http = new Http(url);
											http.addHeader("Authorization", "Bot " + config.tokens.bottoken);
											http.addHeader("Content-Type", "application/json");
											http.setPostData(haxe.Json.stringify({
												type: 0,
												name: target_channel.name,
												permissions_overwrites: [],
												parent_id: parent_id_category
											}));

											http.onData = function(data:String) {
												destination_channel_id = Json.parse(data).id;
											};

											http.onError = function(error:String) {
												throw "Error " + error + " while creating the server channels\nError: " + http.responseData;
											};

											http.request(true);

											var url = "https://discord.com/api/v9/channels/" + destination_channel_id + "/webhooks";

											var http = new Http(url);
											http.addHeader("Authorization", "Bot " + config.tokens.bottoken);
											http.addHeader("Content-Type", "application/json");
											http.setPostData(haxe.Json.stringify({
												name: "Silly webhook"
											}));

											http.onData = function(data:String) {
												var parsed_data:Dynamic = Json.parse(data);
												webhook = parsed_data.url;
											};

											http.onError = function(error:String) {
												throw "Error " + error + " while creating the server channels\nError: " + http.responseData;
											};

											http.request(true);
											// trace("Target channel name: " + target_channel.name + "\nTarget channel ID: " + target_channel.id + "\nDestination channel ID: " + destination_channel_id + "\nWebhook: " + webhook);
											channels_data.push({
												target_channel_name: target_channel.name,
												target_channel_id: target_channel.id,
												destination_channel_id: destination_channel_id,
												webhook: webhook
											});
											Sys.sleep(1); // Prevent rate-limits
										} else {
											Console.log('<red>[Cloner]</> <white>Cannot create channel for ${target_channel.name} as the logging user is not able to see this channel</>');
										}
									}
								}
								Reflect.setField(generated_data, "channels", channels_data);
								Console.log('<red>[Cloner]</> <white>The cloner has been set up successfully, saving data at clonerdata.json</>');
								File.saveContent("clonerdata.json", Json.stringify(generated_data, "\t"));
							} else {
								throw "Something went wrong";
							}
						}

						var clonerdata:String = File.getContent("clonerdata.json");
						cloner_data = Json.parse(clonerdata);
						Console.log('<red>[Cloner]</> <white>Start logging at ${Date.now()}</>');
						logging = true;
						started = true;
					}
				case "MESSAGE_CREATE":
					if (logging) {
						if (d.guild_id == cloner_data.server_details.id) {
							redirectMessage(d);
						}
					}
				case "CHANNEL_CREATE":
					if (logging) {
						if (d.guild_id == cloner_data.server_details.id) {
							Console.log('<red>[Cloner]</> <white>A new channel has been created on the target server. Creating channels and webhooks.</>');
							Console.log('<red>[Cloner]</> <white>Getting logger roles for ${cloner_data.server_details.name}</>');
							var roles:Array<Dynamic> = [];

							var url = "https://discord.com/api/v10/guilds/" + config.servers.target + "/members/" + logger_id;
							var http = new Http(url);
							http.addHeader("Authorization", config.tokens.usertoken);

							http.onData = function(data:String) {
								roles = Json.parse(data).roles;
							};

							http.onError = function(error:String) {
								throw "Error "
									+ error
									+
									" while getting the target server information. The user that's cloning the server might've not joined the server or the server does not exist.\nError: "
									+ http.responseData;
							};

							http.request(false);

							var target_channel:Dynamic = d;
							if (target_channel.type == 0) {
								Console.log('<red>[Cloner]</> <white>Creating channel for ${target_channel.name}</>');

								var canSeeChannel:Bool = true;

								var permission_overwrites:Array<Dynamic> = target_channel.permission_overwrites;
								for (thing in permission_overwrites) {
									if (roles.contains(thing.id)) {
										var deniedPermissions:Array<String> = Permissions.resolve(Int64.fromFloat(Std.parseFloat(thing.deny)));
										if (deniedPermissions.contains("VIEW_CHANNEL")) {
											canSeeChannel = false;
										}
									}
								}

								if (canSeeChannel) {
									var destination_channel_id:String = null;
									var webhook:String = null;

									var url = "https://discord.com/api/v9/guilds/" + config.servers.destination + "/channels";

									var http = new Http(url);
									http.addHeader("Authorization", "Bot " + config.tokens.bottoken);
									http.addHeader("Content-Type", "application/json");
									http.setPostData(haxe.Json.stringify({
										type: 0,
										name: target_channel.name,
										permissions_overwrites: [],
										parent_id: cloner_data.destination_data.parent_id
									}));

									http.onData = function(data:String) {
										destination_channel_id = Json.parse(data).id;
									};

									http.onError = function(error:String) {
										throw "Error " + error + " while creating the server channels\nError: " + http.responseData;
									};

									http.request(true);

									var url = "https://discord.com/api/v9/channels/" + destination_channel_id + "/webhooks";

									var http = new Http(url);
									http.addHeader("Authorization", "Bot " + config.tokens.bottoken);
									http.addHeader("Content-Type", "application/json");
									http.setPostData(haxe.Json.stringify({
										name: "Silly webhook"
									}));

									http.onData = function(data:String) {
										var parsed_data:Dynamic = Json.parse(data);
										webhook = parsed_data.url;
									};

									http.onError = function(error:String) {
										throw "Error " + error + " while creating the server channels\nError: " + http.responseData;
									};

									http.request(true);
									// trace("Target channel name: " + target_channel.name + "\nTarget channel ID: " + target_channel.id + "\nDestination channel ID: " + destination_channel_id + "\nWebhook: " + webhook);
									cloner_data.channels.push({
										target_channel_name: target_channel.name,
										target_channel_id: target_channel.id,
										destination_channel_id: destination_channel_id,
										webhook: webhook
									});

									File.saveContent("clonerdata.json", Json.stringify(cloner_data, "\t"));
									Console.log('<red>[Cloner]</> <white>New channel saved in clonerdata.json</>');
								} else {
									Console.log('<red>[Cloner]</> <white>Cannot create channel for ${target_channel.name} as the logging user is not able to see this channel</>');
								}
							}
						}
					}
			}
		};
		user_socket.start();
	}
}
