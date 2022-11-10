#!/bin/bash

readonly RED=$'\E[31m'
readonly GREEN=$'\E[32m'
readonly YELLOW=$'\E[33m'
readonly BLUE=$'\E[34m'
readonly NOCOLOR=$'\E[0m'

errr() { printf "%sERROR:%s %s\n\n" "$RED" "$NOCOLOR" "$*" >&2; exit 1; }
warn() { printf "%sWARNING:%s %s\n\n" "$YELLOW" "$NOCOLOR" "$*" >&2; }
info() { printf "%sInfo:%s %s\n\n" "$BLUE" "$NOCOLOR" "$*" >&2; }

# Prompts the user for input and validates against provided options
user_selection() {
    local prompt=$1
    shift
    local selection
    read -rp "$prompt" selection
    for option in $(seq "$count") "${options[@]^^}" "${options[@],,}"; do
        if [[ "$selection" == "$option" ]]; then
            if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= count && ${#options[@]} > 0 )); then
                selection=${options[$(( selection - 1 ))]^^}
            fi
            echo "$selection"
            return 0
        fi
    done
    echo "$selection"
    return 1
}

# Convert a time specification like hours:minutes:seconds, minutes:seconds, or just seconds.
# Also allow for fractional seconds through decimals on the seconds or by giving time in ms or us
parse_timespec_to_seconds() {
    local timespec=$1

    if ! grep -Eq -- "^(([0-9]{1,2}:){0,2}[0-9]{1,2}(\.[0-9]+)?|[0-9]+(\.[0-9]+)?((u|m)?s)?)$" <<< "$timespec"; then
        warn "Invalid timespec '$timespec'!"
        return 1
    fi

    local seconds minutes hours
    read -r seconds minutes hours < <(awk -F ':' '{ for (i=NF;i>0;i--) printf("%s ",$i)}' <<< "$timespec")
    if [[ "$seconds" =~ ms ]]; then
        seconds=$(sed 's/[^0-9]//g' <<< "$seconds" | awk '{ printf("%f", $0 / 10**3 ) }')
    elif [[ "$seconds" =~ us ]]; then
        seconds=$(sed 's/[^0-9]//g' <<< "$seconds" | awk '{ printf("%f", $0 / 10**6 ) }')
    fi
    local integer_seconds; integer_seconds=$(awk -F '.' '{ print $1 }' <<< "$seconds")
    local fractional_seconds; fractional_seconds=$(awk -F '.' '{ print $2 }' <<< "$seconds" | sed 's/0*$//')
    if (( 10#$integer_seconds > 59 )); then
        minutes=$(( minutes + 1 ))
        integer_seconds=$(( seconds - 60 ))
    fi
    if (( 10#$minutes > 59 )); then
        hours=$(( hours + 1 ))
        minutes=$(( minutes - 60 ))
    fi
    seconds="$(awk -v s="$integer_seconds" -v m="$minutes" -v h="$hours" 'BEGIN { printf("%s",s + 60*m + 60*60*h) }')"
    if [[ "$fractional_seconds" ]]; then
        seconds+=".$fractional_seconds"
    fi
    echo "$seconds"
}

# Play the clip in VLC media player
play_clip() {
    local vlc_clip
    if [[ "${vlc:?}" == *vlc.exe ]]; then
        vlc_clip=$(wslpath -w "$1")
    else
        vlc_clip=$1
    fi

    if kill -0 "$create_clip_pid" 2>/dev/null; then
        echo
        info "Please wait while clip creation finishes."
        wait "$create_clip_pid"
    fi
    if kill -0 "$vlc_pid" 2>/dev/null; then
        echo
        info "You must close the first instance of VLC to open another one."
        wait "$vlc_pid"
    fi
    "${vlc:?}" "$vlc_clip" &>/dev/null &
    vlc_pid=$!
}

# Provide the user with main options and take actions accordingly
select_program() {
    start_options
    numbered_option "A test (original quality)" "A"
    numbered_option "B test (${bitrate::-1} kbps lossy)" "B"
    if ! "$x_test_completed"; then
        numbered_option "X test (unknown)" "X"
    fi
    numbered_option "Re-clip track" "R"
    if ! "$x_test_attempted" || "$x_test_completed"; then
        numbered_option "Next track" "N"
    fi
    if [[ "$random" =~ [Yy] ]]; then
        numbered_option "Search next track" "F"
    fi
    numbered_option "Change bitrate" "C"
    if (( ${#results[@]} > 0 )); then
        numbered_option "Print results" "P"
    fi
    numbered_option "Reset score" "T"
    numbered_option "Save clip" "S"
    numbered_option "Quit" "Q"

    while ! program_selection=$(user_selection "Selection: "); do
        return 1
    done
    echo
    if [[ "$program_selection" =~ ^[0-9]+$ ]]; then
        program_selection=${options[$(( program_selection - 1 ))]}
    fi
    case "$program_selection" in
        A|a)
            format=original
            play_clip "$original_clip"
            ;;
        B|b)
            format=lossy
            play_clip "$lossy_clip"
            ;;
        X|x)
            if [[ ! -f "$x_clip" ]]; then
                x_clip=$(mktemp --suffix=.wav)
            fi
            if (( x_clip_quality )); then
                format=original
                cp "$original_clip" "$x_clip"
            else
                format=lossy
                cp "$lossy_clip" "$x_clip"
            fi
            play_clip "$x_clip"
            x_test
            ;;
        S|s)
            save_clip ;;
        P|p)
            print_results ;;
        F|f)
            search_anyway=true ;;
        C|c)
            select_bitrate
            create_clip &
            create_clip_pid=$!
            ;;
        T|t)
            warn "Resetting score"
            print_results
            correct=0
            incorrect=0
            skipped=0
            accuracy=0
            results=()
            ;;
        N|n)
            if ! "$x_test_attempted" && ! "$x_test_completed"; then
                skipped=$(( skipped + 1 ))
                track_info=${track_details_map["$track"]}
                result="$(( ${#results[@]} + 1 ))|$track_info|Skipped|${YELLOW}Skipped${NOCOLOR}"
                results+=( "$result" )
            fi
            ;;
        Q|q)
            if ! "$x_test_completed"; then
                track_info=${track_details_map["$track"]}
                result="$(( ${#results[@]} + 1 ))|$track_info|Quit|${YELLOW}Quit${NOCOLOR}"
                results+=( "$result" )
            fi
            quit=true
            exit 0
            ;;
        R|r)
            start_options "Input timestamps manually or have them randomly generated?"
            numbered_option "Manual timestamps" "M"
            numbered_option "Random timestamps" "R"
            while ! timestamp_selection=$(user_selection "Selection: "); do
                warn "Invalid selection: '$timestamp_selection'"
            done
            echo
            if [[ "$timestamp_selection" =~ [Mm] ]]; then
                user_timestamps
            else
                if ! random_timestamps; then
                    warn "Something went wrong with random timestamps"
                    return 1
                fi
            fi
            create_clip &
            create_clip_pid=$!
            ;;
        *)
            return 1 ;;
    esac
}

# Print an incrementing list
numbered_option() {
    local string=$1
    local letter=$2
    if [[ "$letter" ]]; then
        printf "%s/%s) %s\n" "$(( ++count ))" "$letter" "$string"
        options+=( "$letter" )
    else
        printf "%s) %s\n" "$(( ++count ))" "$string"
    fi
}

# Create an original-quality clip and a lossy clip from a given track at the given timestamps
# Obfuscate both original quality and lossy clips as .wav so it cannot easily be determined which is the X file
create_clip() {
    if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
        local ffmpeg_track="$track_w"
        local ffmpeg_original_clip="$original_clip_w"
        local ffmpeg_lossy_clip="$lossy_clip_w"
    else
        local ffmpeg_track="$track"
        local ffmpeg_original_clip="$original_clip"
        local ffmpeg_lossy_clip="$lossy_clip"
    fi

    trap 'rm -f "$tmp_mp3"' RETURN
    local tmp_mp3; tmp_mp3=$(mktemp --suffix=.mp3)

    "${ffmpeg:?}" -nostdin -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_original_clip" \
        -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$tmp_mp3"

    "${ffmpeg:?}" -nostdin -loglevel error -y -i "$tmp_mp3" "$ffmpeg_lossy_clip"
}

# Generate random timestamps to use for clipping
random_timestamps() {
    clip_duration=30
    local track_duration_int=${durations_map["$track"]}
    if (( track_duration_int < clip_duration)); then
        clip_duration=$track_duration_int
    fi
    startsec=$(shuf -i 0-"$(( track_duration_int - clip_duration ))" -n 1 --random-source=/dev/urandom)
    endsec=$(( startsec + clip_duration ))
    sanitize_timestamps
}

# Prompt the user for timestamps to use for clipping
user_timestamps() {
    unset startsec endsec
    info "Track duration: $(date -u --date=@"${durations_map["$track"]}" +%H:%M:%S | sed -r 's/^00:([0-9]{2}:[0-9]{2})/\1/g')"
    while [[ -z "$startsec" ]]; do
        read -rp "Start timestamp: " startts
        if [[ -z "$startts" || "$startts" =~ ^[Rr]$ ]]; then
            info "Selecting random timestamp for a 30 second clip"
            random_timestamps
        else
            startsec=$(parse_timespec_to_seconds "$startts")
        fi
    done

    while [[ -z "$endsec" ]]; do
        read -rp "End timestamp: " endts
        endsec=$(parse_timespec_to_seconds "$endts")
    done

    sanitize_timestamps
    echo
}

async_cleanup() {
    while kill -0 "$create_clip_pid" 2>/dev/null || kill -0 "$vlc_pid" 2>/dev/null; do
        sleep 0.1
    done
    rm -f "${original_clips[@]}" "${lossy_clips[@]}" "$x_clip"
}

# Trap function to run on exit, dispalying the results and deleting all files used
show_results_and_cleanup() {
    print_results
    async_cleanup &
}

# Ensure that timestamps are valid
sanitize_timestamps() {
    # Ensure no negative start or end times
    if (( $(bc <<< "$startsec < 0") )); then
        startsec=0
    fi
    if (( $(bc <<< "$endsec <= 0") )); then
        endsec=1
    fi

    local track_duration_int=${durations_map["$track"]}
    # Ensure the clip doesn't start or extend past the end of the track
    if (( $(bc <<< "$startsec >= $track_duration_int") )); then
        startsec=$(( track_duration_int - 1 ))
    fi
    if (( $(bc <<< "$endsec > $track_duration_int") )); then
        endsec=$(( track_duration_int ))
    fi

    # Ensure the start is before the end
    if (( $(bc <<< "$endsec < $startsec") )); then
        local tmpvar=$startsec
        startsec=$endsec
        endsec=$tmpvar
    fi
    if (( $(bc <<< "$endsec == $startsec") )); then
        endsec=$(bc <<< "$endsec + 1")
    fi
    clip_duration=$(bc <<< "$endsec - $startsec")
}

# Choose the MP3 bitrate for the lossy clip
select_bitrate() {
    start_options "Select a bitrate for MP3 compression of the lossy file."
    for btrt in 320 256 128 112 96 64 32; do
        if [[ "$bitrate" && "$btrt" == "${bitrate::-1}" ]]; then
            numbered_option "${GREEN}${btrt} kbps${NOCOLOR}"
        else
            numbered_option "$btrt kbps"
        fi
    done
    numbered_option "Custom"
    while ! bitrate_selection=$(user_selection "Selection: "); do
        warn "Invalid selection: '$bitrate_selection'"
    done
    echo
    last_bitrate=$bitrate
    case "$bitrate_selection" in
        1)
            bitrate=320k ;;
        2)
            bitrate=256k ;;
        3)
            bitrate=128k ;;
        4)
            bitrate=112k ;;
        5)
            bitrate=96k ;;
        6)
            bitrate=64k ;;
        7)
            bitrate=32k ;;
        8)
            read -rn4 -p "Bitrate (between 32k and 320k): " bitrate
            if ! [[ "$bitrate" =~ k ]]; then
                bitrate+=k
            fi
            if ! [[ "$bitrate" =~ ^[0-9]+k$ ]]; then
                errr "You must provide a bitrate in the standard format"
            fi
            if (( ${bitrate::-1} < 32 )); then
                bitrate=32k
            elif (( ${bitrate::-1} > 320 )); then
                bitrate=320k
            fi
            info "Bitrate selection is $bitrate"
            ;;
        *)
            errr "Input must be between 1 and $count" ;;
    esac
    if [[ -z "$last_bitrate" || "$bitrate" != "$last_bitrate" ]]; then
        if [[ "$last_bitrate" ]]; then
            warn "Resetting score"
            print_results
        fi
        accuracy=0
        correct=0
        incorrect=0
        skipped=0
        results=()
    fi
}

# Save either the lossy or original clip with a user-friendly name to the clips_dir
# Optional lossless compression to FLAC
save_clip() {
    local save_choice_1
    start_options "Select a quality level to save in."
    numbered_option "Save original quality" "O"
    numbered_option "Save lossy quality" "L"
    while ! save_choice_1=$(user_selection "Selection: "); do
        warn "Invalid selection: '$save_choice_1'"
    done
    echo
    local save_choice_2
    start_options "Select a file format to save in."
    numbered_option "Save as WAV" "W"
    numbered_option "Save as FLAC" "F"
    while ! save_choice_2=$(user_selection "Selection: "); do
        warn "Invalid selection: '$save_choice_2'"
    done
    local artist=${artists_map["$track"]}
    local album=${albums_map["$track"]}
    local title=${titles_map["$track"]}
    local save_file_basename && save_file_basename=$(sed 's/\//-/g' <<< "$artist -- $album -- $title")
    if [[ "$save_choice_1" =~ [Oo] ]]; then
        local compression=original
        local clip_to_save="$original_clip"
    else
        local compression=lossy
        local clip_to_save="$lossy_clip"
    fi
    if [[ "$save_choice_2" =~ [Ww] ]]; then
        local file_fmt=wav
    else
        local file_fmt=flac
    fi
    start_ts=$(date -u --date=@"$startsec" +%H%M%S | sed -r 's/00([0-9]{4})/\1/g')
    end_ts=$(date -u --date=@"$endsec" +%H%M%S | sed -r 's/00([0-9]{4})/\1/g')
    local save_file="$clips_dir/$save_file_basename -- $compression.$start_ts.$end_ts.$file_fmt"

    if kill -0 "$create_clip_pid" 2>/dev/null; then
        echo
        info "Please wait while clip creation finishes."
        wait "$create_clip_pid"
    fi
    echo
    if [[ "$save_choice_2" == 1 ]]; then
        if cp "$clip_to_save" "$save_file"; then
            echo "${compression^} clip saved to:"
            echo "$save_file"
        else
            warn "Could not save $save_file"
        fi
    else
        if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
            touch "$save_file"
            save_file=$(wslpath -w "$save_file")
        fi
        if "${ffmpeg:?}" -nostdin -y -loglevel error -i "$clip_to_save" "$save_file"; then
            echo "${compression^} clip saved to:"
            echo "$save_file"
        else
            warn "Could not save $save_file"
        fi
    fi
    read -rsp "Press enter to continue:" _
    echo
}

# Generate a printout of the results, showing all tracks that have been presented so far
# Along with the results and guesses for each X test
print_results() {
    if (( ${#results[@]} > 0 )); then
        if [[ -z "$quit" ]]; then
            clear
            echo "Current track info:"
            {
                echo "Artist|Album|Title"
                echo "${track_details_map["$track"]}"
            } | column -ts '|'
            echo "Current bitrate: ${bitrate}bps"
        fi
        echo
        {
            echo "Number|Artist|Album|Track|Result|Guess"
            for result in "${results[@]}"; do
                echo "$result"
            done
        } | column -ts '|'
        echo "$accuracy% accuracy, $correct correct out of $(( correct + incorrect )) tries, $skipped skipped"
        if [[ -z "$quit" ]]; then
            read -rsp "Press enter to continue:" _
            echo
        fi
    fi
}

generate_track_details() {
    if [[ "${ffprobe:?}" == *ffprobe.exe ]]; then
        local ffprobe_track; ffprobe_track=$(wslpath -w "$1")
    else
        local ffprobe_track=$1
    fi

    local fmt="default=noprint_wrappers=1:nokey=1"
    local ffprobe_opts
    ffprobe_opts=( -v error -select_streams a -show_entries "stream=duration" -of "$fmt" "$ffprobe_track" )
    local track_duration; track_duration=$("${ffprobe:?}" "${ffprobe_opts[@]}" | sed 's/\r//g')
    local track_duration_int; track_duration_int=$(grep -Eo "^[0-9]*" <<< "$track_duration")
    durations_map["$track"]=$track_duration_int

    if [[ "${mediainfo:?}" == *mediainfo.exe ]]; then
        local mediainfo_track; mediainfo_track=$(wslpath -w "$1")
    else
        local mediainfo_track=$1
    fi
    local mediainfo_output='General;%Artist%|%Album%|%Title%|%BitRate%|%Format%'
    local t_artist t_album t_title t_bitrate t_format
    IFS='|' read -r t_artist t_album t_title t_bitrate t_format < <("${mediainfo:?}" --output="$mediainfo_output" "$mediainfo_track")
    max_length=30

    t_artist=$(ellipsize "$max_length" "$t_artist")
    t_album=$(ellipsize "$max_length" "$t_album")
    t_title=$(ellipsize "$max_length" "$t_title")

    local track_details="$t_artist|$t_album|$t_title"
    track_details_map["$track"]=$track_details
    artists_map["$track"]=$t_artist
    albums_map["$track"]=$t_album
    titles_map["$track"]=$t_title
    bitrate_map["$track"]=$(( t_bitrate / 1024 ))
    format_map["$track"]=$t_format
}

print_clip_info() {
    clear
    echo "Clip information"
    echo "Artist: ${artists_map["$track"]}"
    echo "Album: ${albums_map["$track"]}"
    echo "Title: ${titles_map["$track"]}"
    echo "Avg. Bitrate: ${bitrate_map["$track"]} kbps"
    echo "Format: ${format_map["$track"]}"
    echo "$(date -u --date="@$startsec" +%H:%M:%S) - $(date -u --date="@$endsec" +%H:%M:%S)"
    #echo########################
}

ellipsize() {
    len=$1
    shift
    str=$*
    if (( ${#str} > len + 3 )); then
        echo "${str::$len}..."
    else
        echo "$str"
    fi
}

x_test() {
    forfeit=false
    x_test_attempted=true
    start_options
    numbered_option "Guess" "G"
    numbered_option "Retry" "R"
    numbered_option "Forfeit" "F"
    while ! retry_guess_forfeit=$(user_selection "Selection: "); do
        warn "Invalid selection: '$retry_guess_forfeit'"
        echo
    done
    if [[ "$retry_guess_forfeit" =~ [Rr] ]]; then
        return 0
    elif [[ "$retry_guess_forfeit" =~ [Ff] ]]; then
        incorrect=$(( incorrect + 1 ))
        forfeit=true
        echo
        info "You forfeited. The file was ${format^^}"
        track_info=${track_details_map["$track"]}
        result="$(( ${#results[@]} + 1 ))|$track_info|${format^}|${RED}Forfeit${NOCOLOR}"
        results+=( "$result" )
    fi
    if ! "$forfeit"; then
        unset confirmation
        while ! [[ "$confirmation" =~ [Yy] ]]; do
            echo
            start_options "Which did you just hear?"
            numbered_option "Original quality" "O"
            numbered_option "Lossy compression" "L"
            while ! guess=$(user_selection "Selection: "); do
                warn "Invalid selection: '$guess'"
            done
            echo
            start_options "Are you sure?"
            numbered_option "Yes" "Y"
            numbered_option "No" "N"
            while ! confirmation=$(user_selection "Selection: "); do
                warn "Invalid selection: '$confirmation'"
            done
        done
        if [[ "$guess" =~ [Oo] ]]; then
            guess_fmt=original
        else
            guess_fmt=lossy
        fi
        echo
        if [[ "$guess_fmt" == "$format" ]]; then
            correct=$(( correct + 1 ))
            color=$GREEN
            echo "${color}CORRECT!${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        else
            incorrect=$(( incorrect + 1 ))
            color=$RED
            echo "${color}INCORRECT.${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        fi
        track_info=${track_details_map["$track"]}
        result="$(( ${#results[@]} + 1 ))|$track_info|${format^}|${color}${guess_fmt^}${NOCOLOR}"
        results+=( "$result" )
    fi
    accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
    echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
    echo "$skipped tracks skipped"
    echo
    x_test_completed=true
    read -rsp "Press enter to continue:" _
    echo
}

track_search() {
    trap 'rm -f "$tmp_output"' RETURN
    mapfile -t matched_tracks < <(IFS=$'\n'; grep -Ei "[^/]*$search_string[^/]*$" <<< "${all_tracks[*]}")
    if (( ${#matched_tracks[@]} == 0 )); then
        info "No tracks matched"
        return 1
    elif (( ${#matched_tracks[@]} > 20 )); then
        info "Too many tracks matched"
        return 1
    elif (( ${#matched_tracks[@]} > 1 )); then
        info "Multiple tracks matched: choose the correct track below or press N to select a new track:"
        tracks_list=()
        for i in "${!matched_tracks[@]}"; do
            track=${matched_tracks[$i]}
            generate_track_details "$track"
            duration_sec=${durations_map["$track"]}
            duration_str=$(date -u --date="@$duration_sec" +%M:%S | sed -r 's/00:([0-9]{2}:[0-9]{2})/\1/g')
            track_info=${track_details_map["$track"]}
            tracks_list+=( "$track_info|$duration_str" )
        done
        start_options
        tmp_output=$(mktemp)
        {
            echo "Artist|Album|Title|Duration"
            for entry in "${tracks_list[@]}"; do
                numbered_option "$entry"
            done
        } > "$tmp_output"
        column -ts '|' "$tmp_output"
        while ! index=$(user_selection "Selection: "); do
            warn "Invalid selection: $index"
        done
        if [[ "$index" =~ [Nn] ]]; then
            return 1
        fi
        track=${matched_tracks[$(( index - 1 ))]}
    else
        track=${matched_tracks[0]}
        generate_track_details "$track"
    fi
}

random_track() {
    local max_idx=$(( ${#all_tracks[@]} - 1 ))
    local rand_idx; rand_idx=$(shuf -i 0-"$max_idx" -n 1 --random-source=/dev/urandom)
    track="${all_tracks[$rand_idx]}"
    generate_track_details "$track"
}

start_options() {
    echo "$*"
    count=0
    options=()
}

config_file="$HOME/audio_abx_test.cfg"
if [[ -f "$config_file" ]]; then
    music_dir=$(awk -F '=' '/^music_dir=/ { print $2 }' "$config_file")
    clips_dir=$(awk -F '=' '/^clips_dir=/ { print $2 }' "$config_file")
fi

while (( $# > 0 )); do
    param=$1
    shift
    case "$param" in
        --music_dir)
            music_dir=$1
            shift
            ;;
        --clips_dir)
            clips_dir=$1
            shift
            ;;
        *)
            errr "Unrecognized parameter '$param'"
    esac
done

if [[ ! -d "$music_dir" ]]; then
    errr "'$music_dir' directory does not exist."
fi

if [[ ! -d "$clips_dir" ]]; then
    errr "'$clips_dir' directory does not exist."
fi

for cmd in ffmpeg vlc mediainfo ffprobe; do
    cmd_set="$cmd=\$(command -v '$cmd.exe') || $cmd=\$(command -v '$cmd')"
    if ! eval "$cmd_set"; then
        warn "'$cmd' was not found"
    fi
done

original_clips=()
lossy_clips=()

select_bitrate
trap show_results_and_cleanup EXIT

start_options "Fully random song and timestamp selection"
numbered_option "Yes" "Y"
numbered_option "No" "N"
while ! random=$(user_selection "Selection: "); do
    warn "Invalid selection: '$random'"
done
echo

start_options "Source file quality selection"
numbered_option "Lossless only" "L"
numbered_option "Mixed lossy/lossless" "M"
while ! source_quality=$(user_selection "Selection: "); do
    warn "Invalid selection: '$source_quality'"
done
echo

if [[ "$source_quality" =~ [Ll] ]]; then
    mapfile -t all_tracks < <(find "$music_dir" -type f -iname "*.flac")
else
    mapfile -t all_tracks < <(find "$music_dir" -type f -a \( -iname "*.flac" -o -iname "*.m4a" -o -iname "*.mp3" \))
fi

if (( ${#all_tracks[@]} == 0 )); then
    errr "No tracks were found in '$music_dir'"
fi

declare -A track_details_map artists_map albums_map titles_map durations_map bitrate_map format_map
search_anyway=false
while true; do
    if kill -0 "$create_clip_pid" 2>/dev/null; then
        kill "$create_clip_pid" 2>/dev/null
    fi
    echo
    if "$search_anyway" || ! [[ "$random" =~ [Yy] ]]; then
        read -rp "Track search string: " search_string
        if [[ -z "$search_string" ]]; then
            random_track
        elif ! track_search; then
            continue
        fi
        search_anyway=false
    else
        random_track
    fi
    track_w=$(wslpath -w "$track")
    if [[ "$search_string" ]]; then
        user_timestamps || errr "Something went wrong with user timestamps"
    else
        random_timestamps || errr "Something went wrong with random timestamps"
    fi

    original_clips+=( "$(mktemp --suffix=.wav)" )
    original_clip=${original_clips[-1]}
    original_clip_w=$(wslpath -w "$original_clip")
    lossy_clips+=( "$(mktemp --suffix=.wav)" )
    lossy_clip=${lossy_clips[-1]}
    lossy_clip_w=$(wslpath -w "$lossy_clip")

    create_clip &
    create_clip_pid=$!

    x_clip_quality=$(( RANDOM%2 ))
    x_test_attempted=false
    x_test_completed=false
    while true; do
        print_clip_info
        while ! select_program; do
            warn "Invalid selection '$program_selection'"
            read -rsp "Press enter to continue:" _
            print_clip_info
        done
        if [[ "$program_selection" =~ [NnFf] ]]; then
            break
        fi
    done
done
