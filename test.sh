#!/bin/zsh
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Evaluator.swift Sources/Normalizer.swift Sources/Dates.swift Sources/Currency.swift Sources/History.swift Sources/VBASuggestions.swift Sources/VBALinter.swift Sources/Grumpiness.swift \
    Tests/main.swift -o build/tests
./build/tests
