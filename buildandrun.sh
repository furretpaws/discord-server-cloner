#!/bin/bash

haxelib git hxWebSockets https://github.com/ianharrigan/hxWebSockets.git
haxelib install Console.hx
haxe build.hxml
neko main.n