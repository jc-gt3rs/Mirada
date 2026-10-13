# Third-party notices

Mirada itself is MIT-licensed (see LICENSE). It includes or is derived from the
following third-party material, which keeps its own license.

## FLX gaze-warping model weights and reference implementation

Mirada bundles model weights converted from the FLX checkpoints in
https://github.com/chihfanhsu/gaze_correction (also redistributed by
https://github.com/WangWilly/gaze-correction-cam, release v0.1.1). Mirada's
model code is a port of that project's TensorFlow implementation.

Paper: Chih-Fan Hsu, Yu-Shuen Wang, Chin-Laung Lei, Kuan-Ta Chen. "Look at Me!
Correcting Eye Gaze in Live Video Communication." ACM Transactions on
Multimedia Computing, Communications, and Applications 15(2), 2019.

Dataset caveat: the weights were trained on the DIRL gaze dataset (37
volunteers). The dataset's own terms of use are not published.

```
Copyright 2019 Chih-Fan Hsu

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

WangWilly/gaze-correction-cam carries the same BSD-3-Clause license text with
the same copyright line.

## Test fixtures

`Tests/Fixtures/clip.mp4` and `Tests/Fixtures/clip_rot90.mp4` are excerpts of
"Video Blog- CBP Super Bowl LII Countdown to Kickoff - Day 1", U.S. Customs and
Border Protection, Office of Public Affairs. Public domain as a work of the U.S.
federal government. Source:
https://commons.wikimedia.org/wiki/File:Video_Blog-_CBP_Super_Bowl_LII_Countdown_to_Kickoff_-_Day_1.webm
They are used only for automated tests, and their use implies no endorsement.

## swift-argument-parser

The `mirada` command-line tool links swift-argument-parser 1.8.2
(https://github.com/apple/swift-argument-parser), Copyright Apple Inc. and the
Swift project authors, licensed under the Apache License 2.0
(https://www.apache.org/licenses/LICENSE-2.0).

## Build-time tools (not shipped)

XcodeGen (MIT) generates the Xcode project. TensorFlow (Apache-2.0),
coremltools (BSD-3-Clause) and NumPy (BSD-3-Clause) convert the model in
`tools/`. None of them is included in the app or the CLI.

## Fonts

Mirada uses the system fonts SF Pro and SF Mono (and Menlo in the camera
extension's resting card), which ship with macOS. No fonts are bundled.
