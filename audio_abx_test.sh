#!/bin/bash

readonly RED=$'\E[31m'
readonly GREEN=$'\E[32m'
readonly YELLOW=$'\E[33m'
readonly BLUE=$'\E[34m'
readonly NOCOLOR=$'\E[0m'

# Functions for printing different message types to the terminal
errr() { printf "%sERROR:%s %s\n\n" "$RED" "$NOCOLOR" "$*" >&2; exit 1; }
warn() { printf "%sWARNING:%s %s\n\n" "$YELLOW" "$NOCOLOR" "$*" >&2; }
info() { printf "%sInfo:%s %s\n\n" "$BLUE" "$NOCOLOR" "$*" >&2; }

# Main program logic
main() {
    term_width=$(tput cols)
    max_field_length=$(( (term_width - 32)/3 ))
    config_file="$HOME/audio_abx_test.cfg"
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
            --config_file)
                config_file=$1
                shift
                ;;
            *)
                errr "Unrecognized parameter '$param'"
        esac
    done
    if [[ -f "$config_file" ]]; then
        [[ -d "$music_dir" ]] || music_dir=$(awk -F '=' '/^music_dir=/ { print $2 }' "$config_file")
        [[ -d "$clips_dir" ]] || clips_dir=$(awk -F '=' '/^clips_dir=/ { print $2 }' "$config_file")
    fi

    if [[ ! -d "$music_dir" ]]; then
        errr "'$music_dir' directory does not exist."
    fi

    cmnds_notfound=()
    for cmd in ffmpeg vlc mediainfo ffprobe; do
        cmd_set="$cmd=\$(command -v '$cmd.exe') || $cmd=\$(command -v '$cmd')"
        if ! eval "$cmd_set"; then
            cmnds_notfound+=( "$cmd" )
        fi
    done
    if (( ${#cmnds_notfound[@]} > 0 )); then
        errr "At least one command was not found: ${cmnds_notfound[*]}"
    fi

    select_mp3_bitrate
    trap show_results_and_cleanup EXIT

    start_numbered_options_list "Fully random song and timestamp selection"
    numbered_options_list_option "Yes" "Y"
    numbered_options_list_option "No" "N"
    while ! random=$(user_selection "Selection: "); do
        warn "Invalid selection: '$random'"
    done
    echo

    start_numbered_options_list "Source file quality selection"
    numbered_options_list_option "All files" "A"
    numbered_options_list_option "Lossless only" "S"
    numbered_options_list_option "Lossy" "Y"
    while ! source_quality=$(user_selection "Selection: "); do
        warn "Invalid selection: '$source_quality'"
    done
    echo

    if [[ "$source_quality" =~ ^[Aa]$ ]]; then
        audio_file_extension_regex='.*\.(flac|alac|wav|aiff|mp3|m4a|aac|ogg|opus|wma)'
    elif [[ "$source_quality" =~ ^[Ss]$ ]]; then
        audio_file_extension_regex='.*\.(flac|alac|wav|aiff)'
    else
        audio_file_extension_regex='.*\.(mp3|m4a|aac|ogg|opus|wma)'
    fi
    mapfile -t all_tracks < <(find "$music_dir" -type f -regextype egrep -iregex "$audio_file_extension_regex")

    if (( ${#all_tracks[@]} == 0 )); then
        errr "No tracks were found in '$music_dir'"
    fi

    track_index=0
    original_clip=''
    lossy_clip=''
    tmp_mp3=''
    vlc_pid=''
    create_clip_pid=''
    max_idx=$(( ${#all_tracks[@]} - 1 ))
    mapfile -t random_order < <(shuf -i 0-"$max_idx" --random-source=/dev/urandom)

    declare -A track_details_map artists_map albums_map titles_map durations_map bitrate_map format_map
    search_anyway=false
    while true; do
        if kill -0 "$create_clip_pid" 2>/dev/null; then
            kill "$create_clip_pid" 2>/dev/null
        fi
        if "$search_anyway" || [[ ! "$random" =~ ^[Yy]$ ]]; then
            read -rp "Track search string: " search_string
            if [[ -z "$search_string" ]]; then
                random_track
            elif ! track_search; then
                continue
            fi
            search_anyway=false
        else
            unset search_string
            random_track
        fi
        if [[ "$search_string" ]]; then
            user_timestamps || errr "Something went wrong with user timestamps"
        else
            random_timestamps || errr "Something went wrong with random timestamps"
        fi

        create_clip

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
            if [[ "$program_selection" =~ ^[NnFf]$ ]]; then
                break
            fi
        done
    done
}

# Reset parameters for numbered options list
start_numbered_options_list() {
    echo "$*"
    count=0
    options=()
}

# Print and store an incrementing list of options for user selection
numbered_options_list_option() {
    local string=$1
    local letter=$2
    if [[ "$letter" ]]; then
        printf "%s/%s) %s\n" "$(( ++count ))" "$letter" "$string"
        options+=( "$letter" )
    else
        printf "%s) %s\n" "$(( ++count ))" "$string"
    fi
}

# Prompts the user for input and validates against provided options
user_selection() {
    local selection
    read -rp "$1" selection
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

# Provide the user with main options and take actions accordingly
select_program() {
    start_numbered_options_list
    numbered_options_list_option "A test (original quality)" "A"
    numbered_options_list_option "B test (${bitrate::-1} kbps lossy)" "B"
    if ! "$x_test_completed"; then
        numbered_options_list_option "X test (unknown)" "X"
    fi
    numbered_options_list_option "Re-clip track" "R"
    if ! "$x_test_attempted" || "$x_test_completed"; then
        numbered_options_list_option "Next track" "N"
        if [[ "$random" =~ ^[Yy]$ ]]; then
            numbered_options_list_option "Search next track" "F"
        fi
    fi
    numbered_options_list_option "Change bitrate" "C"
    if (( ${#results[@]} > 0 )); then
        numbered_options_list_option "Print results" "P"
        numbered_options_list_option "Reset score" "T"
    fi
    if [[ -d "$clips_dir" ]]; then
        numbered_options_list_option "Save clip" "S"
    fi
    numbered_options_list_option "Quit" "Q"

    while ! program_selection=$(user_selection "Selection: "); do
        return 1
    done
    echo
    if [[ "$program_selection" =~ ^[0-9]+$ ]]; then
        program_selection=${options[$(( program_selection - 1 ))]}
    fi
    case "$program_selection" in
        A|a)
            play_clip "$original_clip" ;;
        B|b)
            play_clip "$lossy_clip" ;;
        X|x)
            if [[ ! -f "$x_clip" ]]; then
                x_clip=$(mktemp --suffix=.wav)
            fi
            original_clip_modtime=$(stat -c "%Y" "$original_clip")
            x_clip_modtime=$(stat -c "%Y" "$x_clip")
            if [[ ! -s "$x_clip" ]] || (( original_clip_modtime > x_clip_modtime )); then
                if (( x_clip_quality )); then
                    format=original
                    cp "$original_clip" "$x_clip"
                else
                    format=lossy
                    cp "$lossy_clip" "$x_clip"
                fi
            fi
            play_clip "$x_clip"
            x_test
            ;;
        S|s)
            save_clip ;;
        P|p)
            print_results ;;
        F|f)
            if ! "$x_test_attempted" && ! "$x_test_completed"; then
                add_result skipped
            fi
            search_anyway=true
            ;;
        C|c)
            select_mp3_bitrate
            create_clip
            ;;
        T|t)
            reset_score ;;
        N|n)
            if ! "$x_test_attempted" && ! "$x_test_completed"; then
                add_result skipped
            fi
            ;;
        Q|q)
            if ! "$x_test_completed"; then
                add_result quit
            fi
            quit=true
            exit 0
            ;;
        R|r)
            start_numbered_options_list "Input timestamps manually or have them randomly generated?"
            numbered_options_list_option "Manual timestamps" "M"
            numbered_options_list_option "Random timestamps" "R"
            while ! timestamp_selection=$(user_selection "Selection: "); do
                warn "Invalid selection: '$timestamp_selection'"
            done
            echo
            if [[ "$timestamp_selection" =~ ^[Mm]$ ]]; then
                user_timestamps
            else
                if ! random_timestamps; then
                    warn "Something went wrong with random timestamps"
                    return 1
                fi
            fi
            create_clip
            ;;
        *)
            return 1 ;;
    esac
}

# Add track and X-test result information to the list of results
add_result() {
    local track_info result numresults
    track_info=${track_details_map["$track"]}
    numresults=$(( ${#results[@]} + 1 ))
    if [[ "$1" == skipped ]]; then
        skipped=$(( skipped + 1 ))
        result="$numresults|$track_info|Skipped|${YELLOW}Skipped${NOCOLOR}"
    elif [[ "$1" == quit ]]; then
        result="$numresults|$track_info|Quit|${YELLOW}Quit${NOCOLOR}"
    elif [[ "$1" == forfeit ]]; then
        incorrect=$(( incorrect + 1 ))
        result="$numresults|$track_info|Forfeit|${RED}Forfeit${NOCOLOR}"
    elif [[ "$1" && "$2" && "$1" == "$2" ]]; then
        correct=$(( correct + 1 ))
        result="$numresults|$track_info|${1^}|${GREEN}${2^}${NOCOLOR}"
    elif [[ "$1" && "$2" && "$1" != "$2" ]]; then
        incorrect=$(( incorrect + 1 ))
        result="$numresults|$track_info|${1^}|${RED}${2^}${NOCOLOR}"
    else
        return 1
    fi
    results+=( "$result" )
}

# Choose the MP3 bitrate for the lossy clip
select_mp3_bitrate() {
    clear -x
    start_numbered_options_list "Select a bitrate for MP3 compression of the lossy file."
    if [[ "$last_bitrate" ]]; then
        warn "Changing your bitrate will reset your score and progress."
    fi
    for btrt in 32 64 96 112 128 256 320; do
        if [[ "$bitrate" && "$btrt" == "${bitrate::-1}" ]]; then
            numbered_options_list_option "${GREEN}${btrt} kbps${NOCOLOR}"
        else
            numbered_options_list_option "$btrt kbps"
        fi
    done
    numbered_options_list_option "Custom"
    while ! bitrate_selection=$(user_selection "Selection: "); do
        warn "Invalid selection: '$bitrate_selection'"
    done
    echo
    case "$bitrate_selection" in
        1)
            bitrate=32k ;;
        2)
            bitrate=64k ;;
        3)
            bitrate=96k ;;
        4)
            bitrate=112k ;;
        5)
            bitrate=128k ;;
        6)
            bitrate=256k ;;
        7)
            bitrate=320k ;;
        8)
            read -rn4 -p "Bitrate (between 32k and 320k): " bitrate
            if [[ ! "$bitrate" =~ k ]]; then
                bitrate+=k
            fi
            if [[ ! "$bitrate" =~ ^[0-9]+k$ ]]; then
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
        reset_score
    fi
    last_bitrate=$bitrate
}

# Resets the user's score to zero and empties their results list
reset_score() {
    if [[ "$last_bitrate" ]]; then
        print_results
    fi
    accuracy=0
    correct=0
    incorrect=0
    skipped=0
    results=()
}

# Prompt the user for a string and then search for tracks with titles matching the string
# String may be any valid regex grep -E accepts except for line termination markers
track_search() {
    if [[ ! -f "$tmp_output" ]]; then
        tmp_output=$(mktemp)
    fi

    echo
    mapfile -t matched_track_indices < <(IFS=$'\n'; iconv -f utf8 -t ascii//TRANSLIT <<< "${all_tracks[*]}" |
            grep -Ein "[^/]*${search_string}[^/]*$" | awk -F ':' '{ print $1 }')
    if (( ${#matched_track_indices[@]} == 0 )); then
        info "No tracks matched"
        return 1
    elif (( ${#matched_track_indices[@]} > 20 )); then
        info "Too many tracks matched"
        return 1
    else
        info "Select the desired track below:"
        tracks_list=()
        for i in "${matched_track_indices[@]}"; do
            track=${all_tracks[$(( i - 1 ))]}
            generate_track_details "$track"
            duration_str=$(seconds_to_timespec "${durations_map["$track"]}")
            track_info=${track_details_map["$track"]}
            tracks_list+=( "$track_info|$duration_str" )
        done
        start_numbered_options_list
        {
            echo "Artist|Album|Title|Duration"
            for entry in "${tracks_list[@]}"; do
                numbered_options_list_option "$entry"
            done
            numbered_options_list_option "Select a new track"
        } > "$tmp_output"
        column -ts '|' "$tmp_output"
        while ! track_selection=$(user_selection "Selection: "); do
            warn "Invalid selection: $track_selection"
        done
        if [[ "$track_selection" == "$count" ]]; then
            return 1
        fi
        selected_track_index=$(( ${matched_track_indices[$(( track_selection - 1 ))]} - 1 ))
        track=${all_tracks[$selected_track_index]}
    fi
}

# As track list is already randomly sorted, just iterate through it
random_track() {
    random_index=${random_order[$track_index]}
    track=${all_tracks[$random_index]}
    generate_track_details "$track"
    if (( ++track_index >= ${#all_tracks[@]} )); then
        track_index=0
    fi
}

# Read track metadata such as duration, title, album, artist, bitrate, and encoding format
generate_track_details() {
    if [[ "${ffprobe:?}" == *ffprobe.exe ]]; then
        local ffprobe_track; ffprobe_track=$(wslpath -w "$1")
    else
        local ffprobe_track=$1
    fi

    local fmt="default=noprint_wrappers=1:nokey=1"
    local ffprobe_opts
    ffprobe_opts=( -v fatal -select_streams a -show_entries "stream=duration" -of "$fmt" "$ffprobe_track" )
    local track_duration; track_duration=$("${ffprobe:?}" "${ffprobe_opts[@]}" | sed 's/\r//g')
    local track_duration_int; track_duration_int=$(grep -Eo "^[0-9]*" <<< "$track_duration")
    durations_map["$track"]=$track_duration_int

    if [[ "${mediainfo:?}" == *mediainfo.exe ]]; then
        local mediainfo_track; mediainfo_track=$(wslpath -w "$1")
    else
        local mediainfo_track=$1
    fi
    local mediainfo_output='General;%Artist%|%Album%|%Title%|%BitRate%|%Format%'
    local track_artist track_album track_title track_bitrate track_format
    IFS='|' read -r track_artist track_album track_title track_bitrate track_format < \
            <("${mediainfo:?}" --output="$mediainfo_output" "$mediainfo_track")

    track_artist_ellipsized=$(ellipsize "$track_artist")
    track_album_ellipsized=$(ellipsize "$track_album")
    track_title_ellipsized=$(ellipsize "$track_title")

    track_details_map["$track"]="$track_artist_ellipsized|$track_album_ellipsized|$track_title_ellipsized"
    artists_map["$track"]=$track_artist
    albums_map["$track"]=$track_album
    titles_map["$track"]=$track_title
    bitrate_map["$track"]=$(( track_bitrate / 1024 ))
    format_map["$track"]=$track_format
}

# Truncates lengthy fields and adds ellipsis to indicate such
ellipsize() {
    str=$*
    if (( ${#str} > max_field_length + 3 )); then
        cut -c 1-"$max_field_length" <<< "$str" | sed -e 's/\s*$//' -e 's/$/.../'
    else
        echo "$str"
    fi
}

# Wrapper around the async portion, allocates the temp filenames
create_clip() {
    # There should be only one encoding task running at a time
    # the last one should've been killed but wait for it to be completely gone
    wait "$create_clip_pid"
    rm -f "$original_clip" "$lossy_clip" "$tmp_mp3"

    original_clip=$(mktemp --suffix=.wav)
    lossy_clip=$(mktemp --suffix=.wav)
    tmp_mp3=$(mktemp --suffix=.mp3)
    create_clip_async &
    create_clip_pid=$!
}

# Create an original-quality clip and a lossy clip from a given track at the given timestamps
# Obfuscate both original quality and lossy clips as .wav so it cannot easily be determined which is the X file
create_clip_async() {
    if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
        local ffmpeg_track; ffmpeg_track=$(wslpath -w "$track")
        local ffmpeg_original_clip; ffmpeg_original_clip=$(wslpath -w "$original_clip")
        local ffmpeg_lossy_clip; ffmpeg_lossy_clip=$(wslpath -w "$lossy_clip")
    else
        local ffmpeg_track=$track
        local ffmpeg_original_clip=$original_clip
        local ffmpeg_lossy_clip=$lossy_clip
    fi

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

# Convert seconds to a string in the form of HH:MM:SS for HH > 00 or else MM:SS
seconds_to_timespec() {
    date -u --date=@"$1" +%H:%M:%S | sed -r 's/00:?([0-9]{2}:?[0-9]{2})/\1/g'
}

# Prompt the user for timestamps to use for clipping
user_timestamps() {
    unset startsec endsec
    local startts endts
    info "Track duration: $(seconds_to_timespec "${durations_map["$track"]}")"
    while [[ -z "$startsec" ]]; do
        read -rp "Start timestamp: " startts
        if [[ -z "$startts" || "$startts" =~ ^[Rr]$ ]]; then
            info "Selecting random timestamp for a 30 second clip"
            random_timestamps
            return 0
        else
            startsec=$(parse_time_to_seconds "$startts") || unset startsec
        fi
    done

    while [[ -z "$endsec" ]]; do
        read -rp "End timestamp: " endts
        if [[ -z "$endts" ]]; then
            endsec=$(( startsec + 30 ))
        else
            endsec=$(parse_time_to_seconds "$endts") || unset endsec
        fi
    done

    sanitize_timestamps
    echo
}

# Convert a time given in [[HH:]MM:]SS to seconds
# Also convert times 'date' understands like "5 minutes 32 seconds"
parse_time_to_seconds() {
    local timespec=$1
    if [[ "$timespec" =~ ^[0-9:]*$ ]]; then
        local seconds minutes hours
        read -r seconds minutes hours _ < <(awk -F ':' '{ for (i=NF;i>0;i--) printf("%s ",$i)}' <<< "$timespec")
        seconds=${seconds:-0}
        minutes=${minutes:-0}
        hours=${hours:-0}
        if (( 10#$seconds > 59 )); then
            minutes=$(( minutes + 1 ))
            seconds=$(( seconds - 60 ))
        fi
        if (( 10#$minutes > 59 )); then
            hours=$(( hours + 1 ))
            minutes=$(( minutes - 60 ))
        fi
        awk -v s="$seconds" -v m="$minutes" -v h="$hours" 'BEGIN { printf("%s",s + 60*m + 60*60*h) }'
    else
        # Hope the user gave the time in some other format date understands
        date -u --date="January 1 1970 + $timespec" +%s
    fi
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

# Play the clip in VLC media player
play_clip() {
    local vlc_clip
    if [[ "${vlc:?}" == *vlc.exe ]]; then
        vlc_clip=$(wslpath -w "$1")
    else
        vlc_clip=$1
    fi

    if kill -0 "$vlc_pid" 2>/dev/null; then
        echo
        info "You must close the current instance of VLC to open another one."
        wait "$vlc_pid"
    fi
    if kill -0 "$create_clip_pid" 2>/dev/null; then
        echo
        info "Please wait while the encoding job finishes."
        wait "$create_clip_pid"
    fi
    "${vlc:?}" "$vlc_clip" &>/dev/null &
    vlc_pid=$!
}

# Randomly selects the quality for the clip and plays it for the user, then
# asks the user to guess whether the clip is original quality or MP3 compressed
# Allows user to return to menu to try A or B test again or re-clip the current
# track, but the user will not be able to skip ahead to the next track
x_test() {
    forfeit=false
    x_test_attempted=true
    start_numbered_options_list
    numbered_options_list_option "Guess" "G"
    numbered_options_list_option "Retry" "R"
    numbered_options_list_option "Forfeit" "F"
    while ! retry_guess_forfeit=$(user_selection "Selection: "); do
        warn "Invalid selection: '$retry_guess_forfeit'"
        echo
    done
    if [[ "$retry_guess_forfeit" =~ ^[Rr]$ ]]; then
        return 0
    elif [[ "$retry_guess_forfeit" =~ ^[Ff]$ ]]; then
        forfeit=true
        echo
        info "You forfeited. The file was ${format^^}"
        add_result forfeit
    fi
    if ! "$forfeit"; then
        unset confirmation
        while [[ ! "$confirmation" =~ ^[Yy]$ ]]; do
            echo
            start_numbered_options_list "Which did you just hear?"
            numbered_options_list_option "Original quality" "O"
            numbered_options_list_option "Lossy compression" "L"
            while ! guess=$(user_selection "Selection: "); do
                warn "Invalid selection: '$guess'"
            done
            echo
            start_numbered_options_list "Are you sure?"
            numbered_options_list_option "Yes" "Y"
            numbered_options_list_option "No" "N"
            while ! confirmation=$(user_selection "Selection: "); do
                warn "Invalid selection: '$confirmation'"
            done
        done
        if [[ "$guess" =~ ^[Oo]$ ]]; then
            guess_fmt=original
        else
            guess_fmt=lossy
        fi
        echo
        if [[ "$guess_fmt" == "$format" ]]; then
            echo "${GREEN}CORRECT!${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        else
            echo "${RED}INCORRECT.${NOCOLOR} The file was ${format^^} and your guess was ${guess_fmt^^}"
        fi
        add_result "$format" "$guess_fmt"
    fi
    accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
    echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
    echo "$skipped tracks skipped"
    echo
    x_test_completed=true
    read -rsp "Press enter to continue:" _
    echo
}

# Save either the lossy or original clip with a user-friendly name to the clips_dir
# Optional lossless compression to FLAC
save_clip() {
    local save_choice_1
    start_numbered_options_list "Select a quality level to save in."
    numbered_options_list_option "Save original quality" "O"
    numbered_options_list_option "Save lossy quality" "L"
    while ! save_choice_1=$(user_selection "Selection: "); do
        warn "Invalid selection: '$save_choice_1'"
    done
    echo
    local save_choice_2
    start_numbered_options_list "Select a file format to save in."
    numbered_options_list_option "Save as WAV" "W"
    numbered_options_list_option "Save as FLAC" "F"
    while ! save_choice_2=$(user_selection "Selection: "); do
        warn "Invalid selection: '$save_choice_2'"
    done
    local artist=${artists_map["$track"]}
    local album=${albums_map["$track"]}
    local title=${titles_map["$track"]}
    local save_file_basename && save_file_basename=$(sed 's/\//-/g' <<< "$artist -- $album -- $title")
    if [[ "$save_choice_1" =~ ^[Oo]$ ]]; then
        local compression=original
        local clip_to_save="$original_clip"
    else
        local compression=lossy
        local clip_to_save="$lossy_clip"
    fi
    if [[ "$save_choice_2" =~ ^[Ww]$ ]]; then
        local file_fmt=wav
    else
        local file_fmt=flac
    fi
    start_ts=$(seconds_to_timespec "$startsec" | tr -d ':')
    end_ts=$(seconds_to_timespec "$endsec" | tr -d ':')
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

# Print out details about the clip
print_clip_info() {
    clear -x
    echo "Clip information"
    echo "Artist: ${artists_map["$track"]}"
    echo "Album: ${albums_map["$track"]}"
    echo "Title: ${titles_map["$track"]}"
    echo "Avg. Bitrate: ${bitrate_map["$track"]} kbps"
    echo "Format: ${format_map["$track"]}"
    echo "Track duration: $(seconds_to_timespec "${durations_map["$track"]}")"
    echo "Clip from $(seconds_to_timespec "$startsec") - $(seconds_to_timespec "$endsec")"
}

# Generate a printout of the results, showing all tracks that have been presented so far
# Along with the results and guesses for each X test
print_results() {
    if (( ${#results[@]} > 0 )); then
        if [[ -z "$quit" ]]; then
            clear -x
            echo "Current track info:"
            {
                echo "Artist|Album|Title"
                echo "${track_details_map["$track"]}"
            } | column -ts '|'
        fi
        echo
        echo "Bitrate: ${bitrate}bps"
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

# Trap function to run on exit, displaying the results and deleting all files used
show_results_and_cleanup() {
    print_results
    async_cleanup &
}

# Allows terminal to return to the user while program cleans up
async_cleanup() {
    if kill -0 "$create_clip_pid" 2>/dev/null; then
        kill "$create_clip_pid" 2>/dev/null
    fi
    while kill -0 "$vlc_pid" 2>/dev/null; do
        sleep 0.1
    done
    while kill -0 "$create_clip_pid" 2>/dev/null; do
        sleep 0.1
    done
    rm -f "$original_clip" "$lossy_clip" "$tmp_mp3" "$tmp_output" "$x_clip"
}

main "$@"
