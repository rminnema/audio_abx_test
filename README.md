# Audio ABX Test

## Introduction

Audio ABX Test is a utility intended for users to perform A/B/X testing of audio files in their music library. The comparison is done between the high quality original files in the user's library versus a lower quality encoding of the same file. The utility is designed to provide a testing environment that disallows cheating and provides feedback to the user on their guesses. Audio ABX Test may also be used to generate clips at arbitrary positions within songs, either randomly or by user selection.

## Usage

`./audio_abx_test.sh [OPTIONS]`

OPTIONS:
- --config\_file: Path to a configuration file containing parameters for music\_dir and clips\_dir. Options given in the configuration file are overridden by options given on the command line. Assumed path for config\_file is ~/audio\_abx\_test.cfg. The format for the configuration file is just `KEY=VALUE` with no quotation marks
- --music\_dir: Path to the directory containing music tracks for use in ABX testing.
- --clips\_dir: Path to the directory where you wish to store clips.

After launching the script by typing the above command in the directory where it resides, you will be provided with options. First select the desired encoding quality of the MP3 file (higher quality means more difficulty in the X-test), whether clip selection is random by default, and whether the pool of all tracks used is only those that are losslessly encoded, or any valid music file.

Once these selection sare made, audio\_abx\_test.sh presents the user with a main menu. The user may select among the following options. Some options may not be present depending on the context.

1. A-test. Listen to the current clip in the original quality.
1. B-test. Listen to the clip in the MP3-compressed quality.
1. X-test. For each clip, the X-test quality is randomly selected to be either original or MP3-compressed quality. The user is not told which they are listening to, and is asked whether they want to guess, proceed back to the main menu, or forfeit their attempt. Once the X-test is attempted a user cannot proceed to the next track (but they may reclip the current track) until they make a guess or forfeit.
1. Re-clip track. The user may have random timestamps selected for a 30 second clip, or they may input timestamps for the clip manually.
1. Next track. Skip to the next track. If no X-test was completed, the results will register a "skip" for the current track.
1. Find next track. Do a regex search on tracks to select the next track. Same as next track, registers as a "skip" if no X-test was completed.
1. Change bitrate. Change the bitrate that the MP3-encoded file is compressed to. If this option is used and the bitrate is changed, the current results list is printed out and then cleared along with the user's score.
1. Reset score. Prints out the current results and score, then clears them.
1. Print results. Prints out the current results and score.
1. Save clip. Presents the user with options to save the current clip in the directory they specified at startup or in the configuration file. The user is allowed to save either the lossy or original quality and as a .WAV or .FLAC.
1. Quit. Prints out the current results and score and then exits the script.

## Dependencies

- ffmpeg
- ffprobe
- mediainfo
- vlc
