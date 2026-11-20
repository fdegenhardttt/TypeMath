# TypeMath

A tiny macOS menu bar app that answers maths wherever you type.

Type an equation ending in `=` in any app and the answer appears next to your cursor.

| You type | Press | You get |
|---|---|---|
| `so it's 4*4 = ` | `=` | `so it's 4*4 = 16` |
| `so it's 4*4 = ` | `Tab` | `so it's 16` |
| `5 km in miles =` | `Tab` | `3.1069 miles` |
| `f(x) = x^2` | | a live graph |

## What it understands

- **Arithmetic:** `+ - * / x × ÷ ^ **`, brackets, implicit multiplication (`2(3+4)`, `2pi`), thousands commas (`1,000`).
- **Percent, calculator-style:** `200 + 10% =` gives 220; `200*15% =` gives 30.
- **Functions and constants:** `sin cos tan asin acos atan sinh cosh tanh sqrt cbrt ln log log2 exp abs round floor ceil`, `5!`, `90°`, `pi π e tau`.
- **Unit conversion:** `<amount> <unit> in|to|as <unit> =` across length, area, mass, volume, temperature, time, speed, energy, power, pressure, angle, frequency, data and data rate.
- **Graphs:** any expression in `x` ending in `=` (`x^2 - 4 =`), or a definition typed as `f(x) = …` or `y = …`, which graphs live as you type.

`x` means multiply between numbers (`4x4`, `4 x (2+3)`) and is the variable otherwise (`2x`, `x(x+1)`).

## Install

Requires macOS 13 or later and the Xcode command line tools.

```bash
./build.sh
open ~/Applications/TypeMath.app
```

On first launch, allow TypeMath in **System Settings → Privacy & Security → Accessibility**. It needs this to read what you type and to type answers in. It skips password fields.

From the menu bar icon you can turn TypeMath off, turn it off for the app you're in, or open it at login.

## Development

```bash
./test.sh
```

Runs the parser tests in `Tests/main.swift`.

- `Sources/Evaluator.swift`: finds and evaluates the equation before the cursor; units table.
- `Sources/main.swift`: keyboard event tap, reading text via Accessibility, typing answers, menu.
- `Sources/Popup.swift`: the answer and graph popup.

`build.sh` signs with an Apple Development certificate if you have one, so the Accessibility permission survives rebuilds. Without one it signs ad-hoc, and macOS asks for the permission again after each build.

## License

MIT
