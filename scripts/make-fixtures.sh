#!/usr/bin/env bash
#
# Regenerates the tiny synthetic clips in TestMedia/ used by the unit tests.
# The generated files are committed, so you normally never need to run this.
#
# Needs a *full* ffmpeg (libx264, libx265, libsvtav1, libvpx, libopus, libmp3lame),
# mkvmerge (MKVToolNix), python3 and Rust/cargo (for scripts/dvgen, which builds
# synthetic Dolby Vision RPUs with the `dolby_vision` crate).
# On a Mac:  brew install ffmpeg mkvtoolnix rust
# These are development tools only; the Reel app never uses them.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/TestMedia"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

for tool in ffmpeg mkvmerge cargo python3; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

FF=(ffmpeg -hide_banner -loglevel error -y -fflags +bitexact)
DUR=3
SIZE=640x360
RATE=24000/1001
VSRC=(-f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DUR")
# One distinct tone per channel so channel mapping can be checked by ear/FFT.
tones() { # $1 = channel count
  local n=$1 inputs=() i
  for ((i = 0; i < n; i++)); do inputs+=(-f lavfi -i "sine=frequency=$((220 + 110 * i)):sample_rate=48000:duration=$DUR"); done
  printf '%s\n' "${inputs[@]}"
}
amerge() { # $1 = first audio input index, $2 = channel count, $3 = layout
  local first=$1 n=$2 layout=$3 pads="" i
  for ((i = 0; i < n; i++)); do pads+="[$((first + i)):a]"; done
  echo "${pads}amerge=inputs=$n,channelmap=channel_layout=$layout,volume=0.25[a]"
}

X265_HDR10="hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:keyint=24:min-keyint=24:log-level=error"
HDR_TAGS=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)

echo "==> HEVC Main10 HDR10 + E-AC-3 5.1 (MKV, with container mastering metadata)"
mapfile -t T6 < <(tones 6)
"${FF[@]}" "${VSRC[@]}" "${T6[@]}" -filter_complex "$(amerge 1 6 5.1)" -map 0:v -map "[a]" \
  -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params "$X265_HDR10" "${HDR_TAGS[@]}" \
  -c:a eac3 -b:a 384k -metadata:s:a:0 language=eng "$TMP/hdr10.mkv"
mkvmerge -q -o "$OUT/hevc_hdr10_eac3.mkv" \
  --colour-matrix 0:9 --colour-range 0:1 --colour-transfer-characteristics 0:16 --colour-primaries 0:9 \
  --max-content-light 0:1000 --max-frame-light 0:400 \
  --chromaticity-coordinates 0:0.680,0.320,0.265,0.690,0.150,0.060 --white-colour-coordinates 0:0.3127,0.3290 \
  --max-luminance 0:1000 --min-luminance 0:0.0001 "$TMP/hdr10.mkv"

echo "==> HEVC Main10 HDR10 + AAC stereo (MP4, hvc1)"
mapfile -t T2 < <(tones 2)
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params "$X265_HDR10" "${HDR_TAGS[@]}" -tag:v hvc1 \
  -c:a aac -b:a 128k -movflags +faststart "$OUT/hevc_hdr10_aac.mp4"

echo "==> H.264 High + AAC stereo (MP4)"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v libx264 -profile:v high -pix_fmt yuv420p -preset veryfast -g 24 -bf 2 \
  -c:a aac -b:a 128k -movflags +faststart "$OUT/h264_aac.mp4"

echo "==> H.264 + AC-3 5.1 (MPEG-TS, Annex B)"
"${FF[@]}" "${VSRC[@]}" "${T6[@]}" -filter_complex "$(amerge 1 6 5.1)" -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 -bf 2 \
  -c:a ac3 -b:a 448k "$OUT/h264_ac3.ts"

echo "==> H.264 + AAC (ADTS) in MPEG-TS as .m2ts"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 \
  -c:a aac -b:a 128k -mpegts_m2ts_mode 1 "$OUT/h264_aac.m2ts"

echo "==> HEVC HLG + AAC (QuickTime MOV)"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
  -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:keyint=24:log-level=error" \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -tag:v hvc1 \
  -c:a aac -b:a 128k "$OUT/hevc_hlg_aac.mov"

echo "==> AV1 10-bit + Opus 5.1 (MKV)"
SVT_LOG=1 "${FF[@]}" "${VSRC[@]}" "${T6[@]}" -filter_complex "$(amerge 1 6 5.1)" -map 0:v -map "[a]" \
  -c:v libsvtav1 -pix_fmt yuv420p10le -preset 12 -g 24 \
  -c:a libopus -b:a 192k -mapping_family 1 "$OUT/av1_opus.mkv"

echo "==> H.264 + TrueHD 5.1 (MKV; FFmpeg's TrueHD encoder stops at 5.1)"
"${FF[@]}" "${VSRC[@]}" "${T6[@]}" -filter_complex "$(amerge 1 6 '5.1(side)')" -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 \
  -c:a truehd -strict -2 "$OUT/h264_truehd51.mkv"

echo "==> H.264 + DTS 5.1 (MKV)"
"${FF[@]}" "${VSRC[@]}" "${T6[@]}" -filter_complex "$(amerge 1 6 5.1)" -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 \
  -c:a dca -strict -2 -b:a 768k "$OUT/h264_dts51.mkv"

echo "==> H.264 + FLAC 7.1 (MKV)"
mapfile -t T8 < <(tones 8)
"${FF[@]}" "${VSRC[@]}" "${T8[@]}" -filter_complex "$(amerge 1 8 7.1)" -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 \
  -c:a flac "$OUT/h264_flac71.mkv"

echo "==> MPEG-2 + MP2 (MPEG-TS)"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v mpeg2video -b:v 2M -g 12 -c:a mp2 -b:a 192k "$OUT/mpeg2_mp2.ts"

echo "==> VP9 profile 2 HDR10 + Opus (WebM)"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v libvpx-vp9 -pix_fmt yuv420p10le -profile:v 2 -deadline realtime -cpu-used 8 -b:v 500k -g 24 "${HDR_TAGS[@]}" \
  -c:a libopus -b:a 96k "$OUT/vp9_hdr_opus.webm"

echo "==> MPEG-4 ASP + MP3 (AVI)"
"${FF[@]}" "${VSRC[@]}" "${T2[@]}" -filter_complex "$(amerge 1 2 stereo)" -map 0:v -map "[a]" \
  -c:v mpeg4 -vtag XVID -q:v 5 -g 24 -c:a libmp3lame -b:a 128k "$OUT/mpeg4_mp3.avi"

echo "==> Subtitles: SRT + ASS in MKV, mov_text in MP4, external .srt sidecar"
cat > "$TMP/subs.srt" <<'SRT'
1
00:00:00,500 --> 00:00:01,500
Hello from <i>Reel</i>

2
00:00:01,700 --> 00:00:02,800
Second line
with a break
SRT
cat > "$TMP/subs.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,24,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
Style: Sign,Helvetica,20,&H0000FFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,1,0,8,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:01.50,Default,,0,0,0,,Styled {\i1}dialogue{\i0}
Dialogue: 0,0:00:01.00,0:00:02.50,Sign,,0,0,0,,{\an8\pos(320,40)}A sign at the top
ASS
"${FF[@]}" "${VSRC[@]}" -i "$TMP/subs.srt" -i "$TMP/subs.ass" -map 0:v -map 1 -map 2 \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 -c:s copy \
  -metadata:s:s:0 language=eng -metadata:s:s:1 language=jpn -disposition:s:1 forced "$OUT/h264_srt_ass.mkv"
"${FF[@]}" "${VSRC[@]}" -i "$TMP/subs.srt" -map 0:v -map 1 \
  -c:v libx264 -pix_fmt yuv420p -preset veryfast -g 24 -c:s mov_text -metadata:s:s:0 language=eng \
  "$OUT/h264_movtext.mp4"
cp "$TMP/subs.srt" "$OUT/h264_aac.srt"

echo "==> Dolby Vision Profile 8.1 and 5 (synthetic RPUs via scripts/dvgen, muxed by mkvmerge)"
cargo build -q --release --manifest-path "$ROOT/scripts/dvgen/Cargo.toml" --target-dir "$TMP/dvgen-target"
DVGEN="$TMP/dvgen-target/release/dvgen"
"${FF[@]}" "${VSRC[@]}" -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
  -x265-params "$X265_HDR10:bframes=0" -f hevc "$TMP/bl_hdr10.hevc"
"${FF[@]}" "${VSRC[@]}" -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
  -x265-params "keyint=24:min-keyint=24:repeat-headers=1:bframes=0:log-level=error" -f hevc "$TMP/bl_p5.hevc"
FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$TMP/bl_hdr10.hevc")
cat > "$TMP/p81.json" <<JSON
{ "cm_version": "V40", "length": $FRAMES, "profile": "8.1",
  "shots": [ { "start": 0, "duration": $FRAMES } ],
  "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1,
              "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }
JSON
sed 's/"8.1"/"5"/' "$TMP/p81.json" > "$TMP/p5.json"
"$DVGEN" "$TMP/p81.json" "$TMP/p81.rpus"
"$DVGEN" "$TMP/p5.json" "$TMP/p5.rpus"
python3 "$ROOT/scripts/dv_inject.py" "$TMP/bl_hdr10.hevc" "$TMP/p81.rpus" "$TMP/p81.hevc"
python3 "$ROOT/scripts/dv_inject.py" "$TMP/bl_p5.hevc" "$TMP/p5.rpus" "$TMP/p5.hevc"
mkvmerge -q -o "$OUT/dv_p81.mkv" --default-duration 0:24000/1001p "$TMP/p81.hevc"
mkvmerge -q -o "$OUT/dv_p5.mkv" --default-duration 0:24000/1001p "$TMP/p5.hevc"
"${FF[@]}" -i "$OUT/dv_p81.mkv" -c copy -tag:v dvh1 -strict unofficial "$OUT/dv_p81.mp4"

echo "==> Done:"
ls -lh "$OUT"
du -sh "$OUT"
