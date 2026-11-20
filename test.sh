#!/bin/zsh
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Evaluator.swift Tests/main.swift -o build/tests
./build/tests
