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
    local options=( "$@" )
    local selection
    read -rp "$prompt" selection
    for option in "${options[@]}"; do
        if [[ "$selection" == "$option" ]]; then
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

    if kill -0 $! 2>/dev/null; then
        info "Please wait while clip creation finishes."
    fi
    wait $!
    "${vlc:?}" "$vlc_clip" &>/dev/null || errr "VLC could not play the clip"
}

# Provide the user with main options and take actions accordingly
select_program() {
    local count=0
    local options=()

    numbered_option "A test (original quality)" "A" && options+=( "A" )
    numbered_option "B test (${bitrate::-1} kbps lossy)" "B" && options+=( "B" )
    if ! grep -q "no_x_test" <<< "$*"; then
        numbered_option "X test (unknown)" "X" && options+=( "X" )
    fi
    numbered_option "Re-clip track" "R" && options+=( "R" )
    if ! grep -q "no_skip" <<< "$*"; then
        numbered_option "Next track" "N" && options+=( "N" )
    fi
    numbered_option "Change bitrate" "C" && options+=( "C" )
    numbered_option "Print results" "P" && options+=( "P" )
    numbered_option "Reset score" "T" && options+=( "T" )
    numbered_option "Save clip" "S" && options+=( "S" )
    numbered_option "Quit" "Q" && options+=( "Q" )

    while ! program_selection=$(user_selection "Selection: " $(seq $count) "${options[@]^^}" "${options[@],,}"); do
        return 1
    done
    if [[ "$program_selection" =~ ^[0-9]+$ ]]; then
        program_selection=${options[$(( program_selection - 1 ))]}
    fi
    case "$program_selection" in
        A|a)
            format=lossless ;;
        B|b)
            format=lossy ;;
        X|x)
            if [[ ! -f "$x_clip" ]]; then
                x_clip=$(mktemp --suffix=.wav)
            fi
            if (( randombit )); then
                format=lossless
                cp "$lossless_clip" "$x_clip"
            else
                format=lossy
                cp "$lossy_clip" "$x_clip"
            fi
            ;;
        S|s)
            save_clip ;;
        P|p)
            print_results ;;
        C|c)
            select_bitrate
            create_clip &
            create_clip_pid=$!
            select_program
            return 0
            ;;
        T|t)
            warn "Resetting score"
            print_results
            correct=0
            incorrect=0
            skipped=0
            accuracy=0
            results=()
            return 0
            ;;
        N|n)
            return 0 ;;
        Q|q)
            exit 0 ;;
        R|r)
            while ! timestamp_selection=$(user_selection "U for user-selected timestamps, R for random: " U u R r); do
                warn "Invalid selection: '$timestamp_selection'"
            done
            if [[ "$timestamp_selection" =~ [Uu] ]]; then
                user_timestamps
            else
                if ! random_timestamps; then
                    warn "Something went wrong with random timestamps"
                    return 0
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
    else
        printf "%s) %s\n" "$(( ++count ))" "$string"
    fi
}

# Create a lossless clip and a lossy clip from a given track at the given timestamps
# Obfuscate both lossless and lossy clips as .wav so it cannot easily be determined which is the X file
create_clip() {
    if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
        local ffmpeg_track="$track_w"
        local ffmpeg_lossless_clip="$lossless_clip_w"
        local ffmpeg_lossy_clip="$lossy_clip_w"
    else
        local ffmpeg_track="$track"
        local ffmpeg_lossless_clip="$lossless_clip"
        local ffmpeg_lossy_clip="$lossy_clip"
    fi

    trap 'rm -f "$tmp_mp3"' RETURN
    local tmp_mp3; tmp_mp3=$(mktemp --suffix=.mp3)

    "${ffmpeg:?}" -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_lossless_clip" \
        -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$tmp_mp3"

    "${ffmpeg:?}" -loglevel error -y -i "$tmp_mp3" "$ffmpeg_lossy_clip"
}

# Generate random timestamps to use for clipping
random_timestamps() {
    clip_duration=30
    local track_duration_int=${durations_map["$track"]}
    if (( track_duration_int < clip_duration)); then
        return 1
    fi
    startsec=$(shuf -i 0-"$(( track_duration_int - clip_duration ))" -n 1 --random-source=/dev/urandom)
    endsec=$(( startsec + clip_duration ))
    sanitize_timestamps
}

# Prompt the user for timestamps to use for clipping
user_timestamps() {
    while true; do
        read -rp "Start timestamp: " startts
        startsec=$(parse_timespec_to_seconds "$startts") && break
    done

    while true; do
        read -rp "End timestamp: " endts
        endsec=$(parse_timespec_to_seconds "$endts") && break
    done

    sanitize_timestamps
}

async_cleanup() {
    while kill -0 "$create_clip_pid" 2>/dev/null; do
        sleep 0.1
    done
    rm -f "${lossless_clips[@]}" "${lossy_clips[@]}" "$x_clip"
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
    count=0
    for btrt in 320 256 128 112 96 64 32; do
        if [[ "$bitrate" && "$btrt" == "${bitrate::-1}" ]]; then
            numbered_option "${GREEN}${btrt} kbps${NOCOLOR}"
        else
            numbered_option "$btrt kbps"
        fi
    done
    numbered_option "Custom"
    while ! bitrate_selection=$(user_selection "Selection: " $(seq "$count")); do
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

# Save either the lossy or lossless clip with a user-friendly name to the clips_dir
# Optional lossless compression to FLAC
save_clip() {
    echo
    local save_choice_1
    while ! save_choice_1=$(user_selection "1 to save lossless, 2 for lossy: " 1 2); do
        warn "Invalid selection: '$save_choice_1'"
    done
    local save_choice_2
    while ! save_choice_2=$(user_selection "1 to save as WAV, 2 as FLAC: " 1 2); do
        warn "Invalid selection: '$save_choice_2'"
    done
    i=1
    local artist=${artists_map["$track"]}
    local album=${albums_map["$track"]}
    local title=${titles_map["$track"]}
    local save_file_basename && save_file_basename=$(sed 's/\//-/g' <<< "$artist -- $album -- $title")
    if [[ "$save_choice_1" == 1 ]]; then
        local compression=lossless
        local clip_to_save="$lossless_clip"
    else
        local compression=lossy
        local clip_to_save="$lossy_clip"
    fi
    if [[ "$save_choice_2" == 1 ]]; then
        local file_fmt=wav
    else
        local file_fmt=flac
    fi
    local save_file="$clips_dir/$save_file_basename -- $compression.$i.$file_fmt"
    while [[ -f "$save_file" ]]; do
        save_file="$clips_dir/$save_file_basename -- $compression.$(( ++i )).$file_fmt"
    done

    if kill -0 $! 2>/dev/null; then
        echo
        info "Please wait while clip creation finishes."
    fi
    wait $!
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
        if "${ffmpeg:?}" -y -loglevel error -i "$clip_to_save" "$save_file"; then
            echo "${compression^} clip saved to:"
            echo "$save_file"
        else
            warn "Could not save $save_file"
        fi
    fi
}

# Generate a printout of the results, showing all tracks that have been presented so far
# Along with the results and guesses for each X test
print_results() {
    echo
    echo "Current bitrate: ${bitrate}bps"
    {
        echo "Number|File|Result|Guess"
        for result in "${results[@]}"; do
            echo "$result"
        done
    } | column -ts '|'
    echo "$accuracy% accuracy, $correct correct out of $(( correct + incorrect )) tries, $skipped skipped"
    echo
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
    local mediainfo_output='General;%Artist%|%Album%|%Title%'
    local t_artist t_album t_title
    IFS='|' read -r t_artist t_album t_title < <("${mediainfo:?}" --output="$mediainfo_output" "$mediainfo_track")
    local track_details="$t_artist -- $t_album -- $t_title"
    if (( ${#track_details} > 90 )); then
        track_details="${track_details::90}..."
    fi
    track_details_map["$track"]=$track_details
    artists_map["$track"]=$t_artist
    albums_map["$track"]=$t_album
    titles_map["$track"]=$t_title
}

print_clip_info() {
    echo "Clip information"
    echo "Artist: ${artists_map["$track"]}"
    echo "Album: ${albums_map["$track"]}"
    echo "Title: ${titles_map["$track"]}"
    echo "$(date -u --date="@$startsec" +%H:%M:%S) - $(date -u --date="@$endsec" +%H:%M:%S)"
    echo
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

lossless_clips=()
lossy_clips=()

select_bitrate
trap show_results_and_cleanup EXIT

while ! random=$(user_selection "Fully random song and timestamp selection (y/n): " Y y N n); do
    warn "Invalid selection: '$random'"
done
#echo

while ! source_quality=$(user_selection "Source quality (L for lossless, M for mixed lossy/lossless): " L l M m); do
    warn "Invalid selection: '$source_quality'"
done
#echo

if [[ "$source_quality" =~ [Ll] ]]; then
    mapfile -t alltracks < <(find "$music_dir" -type f -iname "*.flac")
else
    mapfile -t alltracks < <(find "$music_dir" -type f -a \( -iname "*.flac" -o -iname "*.m4a" -o -iname "*.mp3" \))
fi

if (( ${#alltracks[@]} == 0 )); then
    errr "No tracks were found in '$music_dir'"
fi

declare -A track_details_map artists_map albums_map titles_map durations_map
while true; do
    if ! [[ "$random" =~ [Yy] ]]; then
        read -rp "Track search string: " search_string
    fi
    if [[ -z "$search_string" ]]; then
        info "Will choose a random track"
        max_idx=$(( ${#alltracks[@]} - 1 ))
        rand_idx=$(shuf -i 0-"$max_idx" -n 1 --random-source=/dev/urandom)
        track="${alltracks[$rand_idx]}"
        generate_track_details "$track"
    else
        mapfile -t matched_tracks < <(find "${alltracks[@]}" -maxdepth 0 -iname "*$search_string*")
        if (( ${#matched_tracks[@]} == 0 )); then
            info "No tracks matched"
            continue
        elif (( ${#matched_tracks[@]} > 20 )); then
            info "Too many tracks matched"
            continue
        elif (( ${#matched_tracks[@]} > 1 )); then
            info "Multiple tracks matched: choose the correct track below:"
            tracks_list=()
            for i in "${!matched_tracks[@]}"; do
                track=${matched_tracks[$i]}
                generate_track_details "$track"
                duration_sec=${durations_map["$track"]}
                duration_str=$(date -u --date="@$duration_sec" +%M:%S | sed -r 's/00:([0-9]{2}:[0-9]{2})/\1/g')
                track_info=${track_details_map["$track"]}
                tracks_list+=( "$i|$track_info|$duration_str" )
            done
            {
                echo "Number|Artist|Album|Title|Duration"
                for entry in "${tracks_list[@]}"; do
                    echo "$entry"
                done | sed 's/ -- /|/g'
            } | column -ts '|'
            read -rp "Index: " index
            if [[ -z "$index" || "$index" =~ [^0-9] ]] || (( index >= ${#matched_tracks[@]} )); then
                continue
            fi
            track=${matched_tracks[$index]}
        else
            track=${matched_tracks[0]}
            generate_track_details "$track"
        fi
    fi
    track_w=$(wslpath -w "$track")
    if [[ -z "$search_string" ]]; then
        if ! random_timestamps; then
            warn "Something went wrong with random timestamps"
        fi
    else
        if ! user_timestamps; then
            warn "Something went wrong with user timestamps"
        fi
    fi

    lossless_clips+=( "$(mktemp --suffix=.wav)" )
    lossless_clip=${lossless_clips[-1]}
    lossless_clip_w=$(wslpath -w "$lossless_clip")
    lossy_clips+=( "$(mktemp --suffix=.wav)" )
    lossy_clip=${lossy_clips[-1]}
    lossy_clip_w=$(wslpath -w "$lossy_clip")

    create_clip &
    create_clip_pid=$!

    randombit=$(( RANDOM%2 ))
    no_skip=''
    while true; do
        print_clip_info
        while ! select_program ${no_skip:+no_skip}; do
            warn "Invalid selection '$program_selection'"
            print_clip_info
        done
        case "$program_selection" in
            A|a)
                play_clip "$lossless_clip" ;;
            B|b)
                play_clip "$lossy_clip" ;;
            X|x)
                play_clip "$x_clip" ;;
            N|n)
                if [[ -z "$no_skip" ]]; then
                    skipped=$(( skipped + 1 ))

                    track_info=${track_details_map["$track"]}
                    result="$(( ${#results[@]} + 1 ))|$track_info|Skipped|${YELLOW}Skipped${NOCOLOR}"
                    results+=( "$result" )
                    break
                fi
                ;;
            *)
                continue ;;
        esac
        if [[ "$program_selection" =~ [Xx] ]]; then
            forfeit=false
            no_skip=true
            while ! retry_guess_forfeit=$(user_selection "Guess (G), Retry (R), or forfeit (F): " G g R r F f); do
                warn "Invalid selection: '$retry_guess_forfeit'"
                echo >&2
            done
            if [[ "$retry_guess_forfeit" =~ [Rr] ]]; then
                continue
            elif [[ "$retry_guess_forfeit" =~ [Ff] ]]; then
                incorrect=$(( incorrect + 1 ))
                forfeit=true
                echo
                info "You forfeited. The file was ${format^^}"
                track_info=${track_details_map["$track"]}
                result="$(( ${#results[@]} + 1 ))|$track_info|${format^}|${RED}Forfeit${NOCOLOR}"
                results+=( "$result" )
                break
            fi
            if ! "$forfeit"; then
                unset confirmation
                while ! [[ "$confirmation" =~ [Yy] ]]; do
                    echo
                    echo "Which did you just hear?"
                    while ! guess=$(user_selection "1 for lossless, 2 for lossy: " 1 2); do
                        warn "Invalid selection: '$guess'"
                    done
                    echo
                    while ! confirmation=$(user_selection "Are you sure? (y/n): " Y y N n); do
                        warn "Invalid selection: '$confirmation'"
                    done
                done
                if [[ "$guess" == 1 ]]; then
                    guess_fmt=Lossless
                else
                    guess_fmt=Lossy
                fi
                echo
                if [[ "$guess" == 1 && "$format" == lossless ]] || [[ "$guess" == 2 && "$format" == lossy ]]; then
                    correct=$(( correct + 1 ))
                    color=$GREEN
                    echo "${color}CORRECT!${NOCOLOR} The file was ${format^^}"
                else
                    incorrect=$(( incorrect + 1 ))
                    color=$RED
                    echo "${color}INCORRECT.${NOCOLOR} The file was ${format^^}"
                fi
                track_info=${track_details_map["$track"]}
                result="$(( ${#results[@]} + 1 ))|$track_info|${format^}|${color}${guess_fmt}${NOCOLOR}"
                results+=( "$result" )
            fi
            accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
            echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
            echo "$skipped tracks skipped"
            echo
            break
        fi
    done
    while ! [[ "$program_selection" =~ [Nn] ]]; do
        while ! select_program no_x_test; do
            warn "Invalid program selection '$program_selection'"
        done
        case "$program_selection" in
            A|a)
                play_clip "$lossless_clip" ;;
            B|b)
                play_clip "$lossy_clip" ;;
            *)
                continue ;;
        esac
    done
done
