#!/bin/bash

readonly RED=$'\E[31m'
readonly GREEN=$'\E[32m'
readonly YELLOW=$'\E[33m'
readonly NOCOLOR=$'\E[0m'

errr() { echo "${RED}ERROR:${NOCOLOR} $*" >&2; exit 1; }
warn() { echo "${YELLOW}WARNING:${NOCOLOR} $*" >&2; }

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

parse_timespec_to_seconds() {
    timespec=$1

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

play_clip() {
    if [[ "${vlc:?}" == *vlc.exe ]]; then
        local vlc_clip
        vlc_clip=$(wslpath -w "$1")
    else
        local vlc_clip=$1
    fi

    "${vlc:?}" "$vlc_clip" &>/dev/null || errr "VLC could not play the clip"
}

select_program() {
    count=0
    local options=()
    numbered_option "(A) A test (original quality)" && options+=( "A" )
    numbered_option "(B) B test (${bitrate::-1} kbps lossy)" && options+=( "B" )
    if ! grep -q "no_x_test" <<< "$*"; then
        numbered_option "(X) X test (unknown)" && options+=( "X" )
    fi
    numbered_option "(R) Re-clip track" && options+=( "R" )
    if ! grep -q "no_skip" <<< "$*"; then
        numbered_option "(N) Next track" && options+=( "N" )
    fi
    numbered_option "(C) Change bitrate" && options+=( "C" )
    numbered_option "(P) Print results" && options+=( "P" )
    numbered_option "(T) Reset score" && options+=( "T" )
    numbered_option "(S) Save clip" && options+=( "S" )
    numbered_option "(Q) Quit" && options+=( "Q" )
    while ! program_selection=$(user_selection "Selection: " $(seq $count) "${options[@]^^}" "${options[@],,}"); do
        return 1
    done
    echo
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
            save_clip
            ;;
        P|p)
            print_results
            ;;
        C|c)
            select_bitrate
            create_clip
            select_program
            return 0
            ;;
        T|t)
            warn "Resetting score"
            correct=0
            incorrect=0
            skipped=0
            accuracy=0
            tracks_seen=()
            guesses=()
            results=()
            return 0
            ;;
        N|n)
            return 0
            ;;
        Q|q)
            exit 0
            ;;
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
            create_clip
            ;;
        *)
            return 1 ;;
    esac
}

numbered_option() {
    count=$(( count + 1 ))
    printf "%s. %s\n" "$count" "$*"
}

create_clip() {
    case "${ffmpeg:?}" in
        *.exe)
            local ffmpeg_track="$track_w"
            local ffmpeg_lossless_clip="$lossless_clip_w"
            local ffmpeg_lossy_clip="$lossy_clip_w"
            ;;
        *)
            local ffmpeg_track="$track"
            local ffmpeg_lossless_clip="$lossless_clip"
            local ffmpeg_lossy_clip="$lossy_clip"
            ;;
    esac

    trap 'rm -f "$tmp_mp3"' RETURN
    local tmp_mp3; tmp_mp3=$(mktemp --suffix=.mp3)

    "${ffmpeg:?}" -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_lossless_clip" \
        -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$tmp_mp3"

    "${ffmpeg:?}" -loglevel error -y -i "$tmp_mp3" "$ffmpeg_lossy_clip"
}

random_timestamps() {
    clip_duration=30
    if (( track_duration_int < clip_duration + 30 )); then
        return 1
    fi
    startsec=$(shuf -i 0-"$(( track_duration_int - clip_duration ))" -n 1 --random-source=/dev/urandom)
    endsec=$(( startsec + clip_duration ))
    sanitize_timestamps
}

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

show_results_and_cleanup() {
    print_results
    rm -f "${lossless_clips[@]}" "${lossy_clips[@]}" "$x_clip"
}

sanitize_timestamps() {
    if (( $(bc <<< "$startsec < 0") )); then
        startsec=0
    fi
    if (( $(bc <<< "$endsec < 0") )); then
        endsec=1
    fi
    if (( $(bc <<< "$startsec >= $track_duration") )); then
        startsec=$(( track_duration_int - 1 ))
    fi
    if (( $(bc <<< "$endsec > $track_duration") )); then
        endsec=$(( track_duration_int ))
    fi
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

select_bitrate() {
    count=0
    for btrt in 320 256 128 112 96 64 32; do
        if [[ "$bitrate" && "$btrt" == "${bitrate::-1}" ]]; then
            numbered_option "$GREEN$btrt kbps$NOCOLOR"
        else
            numbered_option "$btrt kbps"
        fi
    done
    numbered_option "Custom"
    while ! bitrate_selection=$(user_selection "Selection: " $(seq "$count")); do
        warn "Invalid selection: '$bitrate_selection'"
    done
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
            echo "Bitrate selection is $bitrate"
            ;;
        *)
            errr "Input must be between 1 and $count" ;;
    esac
    echo
    if [[ -z "$last_bitrate" || "$bitrate" != "$last_bitrate" ]]; then
        [[ "$last_bitrate" ]] && warn "Resetting score"
        accuracy=0
        correct=0
        incorrect=0
        skipped=0
        tracks_seen=()
        guesses=()
        results=()
    fi
}

save_clip() {
    local save_choice_1
    while ! save_choice_1=$(user_selection "1 to save lossless, 2 for lossy: " 1 2); do
        warn "Invalid selection: '$save_choice_1'"
    done
    local save_choice_2
    while ! save_choice_2=$(user_selection "1 to save as WAV, 2 as FLAC: " 1 2); do
        warn "Invalid selection: '$save_choice_2'"
    done
    i=1
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

    if [[ "$save_choice_2" == 1 ]]; then
        if cp "$clip_to_save" "$save_file"; then
            echo "$compression clip saved to $save_file"
        else
            warn "Could not save $save_file"
        fi
    else
        if [[ "${ffmpeg:?}" == *ffmpeg.exe ]]; then
            touch "$save_file"
            save_file=$(wslpath -w "$save_file")
        fi
        if "${ffmpeg:?}" -y -loglevel error -i "$clip_to_save" "$save_file"; then
            echo "$compression clip saved to $save_file"
        else
            warn "Could not save $save_file"
        fi
    fi
    echo
}

print_results() {
    echo
    if (( ${#guesses[@]} != ${#results[@]} || ${#results[@]} != ${#tracks_seen[@]} )); then
        errr "You did something wrong."
    fi
    echo "Current bitrate: ${bitrate}bps"
    {
        echo "Number|File|Result|Guess"
        for (( i=0; i < ${#guesses[@]}; i++ )); do
            local guess=${guesses[$i]}
            local result=${results[$i]}
            if [[ "$guess" == "$result" && "${result^^}" != "SKIPPED" ]]; then
                color=$GREEN
            elif [[ "${result^^}" == "SKIPPED" ]]; then
                color=$YELLOW
            else
                color=$RED
            fi
            echo "$(( i + 1 ))|${tracks_seen[$i]}|$result|$color$guess$NOCOLOR"
        done
    } | column -ts '|'
    echo "$accuracy% accuracy, $correct correct out of $(( correct + incorrect )) tries, $skipped skipped"
    echo
}

if [[ -f mp3compare.cfg ]]; then
    source mp3compare.cfg
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

if [[ ! -d "${music_dir:?}" ]]; then
    errr "'$music_dir' directory does not exist."
fi

if [[ ! -d "${clips_dir:?}" ]]; then
    errr "'$clips_dir' directory does not exist."
fi

commands=( ffmpeg vlc mediainfo ffprobe )
for cmd in "${commands[@]}"; do
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
    echo "Invalid selection: '$random'"
done
echo

while ! source_quality=$(user_selection "Source quality (L for lossless, M for mixed lossy/lossless): " L l M m); do
    echo "Invalid selection: '$source_quality'"
done
echo

if [[ "$source_quality" =~ [Ll] ]]; then
    mapfile -t alltracks < <(find "$music_dir" -type f -iname "*.flac")
else
    mapfile -t alltracks < <(find "$music_dir" -type f -a \( -iname "*.flac" -o -iname "*.m4a" -o -iname "*.mp3" \))
fi

if (( ${#alltracks[@]} == 0 )); then
    errr "No tracks were found in '$music_dir'"
fi

while true; do
    if ! [[ "$random" =~ [Yy] ]]; then
        read -rp "Track search string: " search_string
        echo
    fi
    if [[ -z "$search_string" ]]; then
        echo "Will choose a random track"
        echo
        max_idx=$(( ${#alltracks[@]} - 1 ))
        rand_idx=$(shuf -i 0-"$max_idx" -n 1 --random-source=/dev/urandom)
        track="${alltracks[$rand_idx]}"
    else
        mapfile -t matched_tracks < <(find "$music_dir" -type f -iname "*$search_string*")
        if (( ${#matched_tracks[@]} == 0 )); then
            echo "No tracks matched"
            continue
        elif (( ${#matched_tracks[@]} > 10 )); then
            echo "Too many tracks matched"
            continue
        elif (( ${#matched_tracks[@]} > 1 )); then
            echo "Multiple tracks matched: choose the correct track below:"
            for i in "${!matched_tracks[@]}"; do
                echo "$i : ${matched_tracks[$i]}"
            done
            read -rp "Index: " index
            if [[ -z "$index" || "$index" =~ [^0-9] ]] || (( index >= ${#matched_tracks[@]} )); then
                continue
            fi
            track=${matched_tracks[$index]}
        else
            track=${matched_tracks[0]}
        fi
    fi
    track_w=$(wslpath -w "$track")
    case "${ffprobe:?}" in
        *ffprobe.exe)
            ffprobe_track="$track_w" ;;
        *ffprobe)
            ffprobe_track="$track" ;;
    esac

    fmt="default=noprint_wrappers=1:nokey=1"
    ffprobe_opts=( -v error -select_streams a -show_entries "stream=duration" -of "$fmt" "$ffprobe_track" )
    track_duration=$("${ffprobe:?}" "${ffprobe_opts[@]}" | sed 's/\r//g')
    track_duration_int=$(grep -Eo "^[0-9]*" <<< "$track_duration")
    if [[ -z "$search_string" ]]; then
        if ! random_timestamps; then
            warn "Something went wrong with random timestamps"
        fi
    else
        if ! user_timestamps; then
            warn "Something went wrong with user timestamps"
        fi
    fi

    case "${mediainfo:?}" in
        *.exe)
            mediainfo_track="$track_w" ;;
        *)
            mediainfo_track="$track" ;;
    esac
    IFS='|' read -r artist album title < <("${mediainfo:?}" --output="General;%Artist%|%Album%|%Title%" "$mediainfo_track")

    lossless_clips+=( "$(mktemp --suffix=.wav)" )
    lossless_clip=${lossless_clips[-1]}
    lossless_clip_w=$(wslpath -w "$lossless_clip")
    lossy_clips+=( "$(mktemp --suffix=.wav)" )
    lossy_clip=${lossy_clips[-1]}
    lossy_clip_w=$(wslpath -w "$lossy_clip")

    create_clip

    randombit=$(( RANDOM%2 ))
    no_skip=''
    while true; do
        echo "Clip information"
        echo "Artist: $artist"
        echo "Album: $album"
        echo "Title: $title"
        echo "$(date -u --date="@$startsec" +%H:%M:%S) - $(date -u --date="@$endsec" +%H:%M:%S)"
        echo
        while ! select_program ${no_skip:+no_skip}; do
            warn "Invalid selection '$program_selection'"
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
                    guesses+=( "Skipped" )
                    results+=( "Skipped" )
                    trackinfo="$artist - $album - $title"
                    tracks_seen+=( "$trackinfo" )
                    skipped=$(( skipped + 1 ))
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
            done
            if [[ "$retry_guess_forfeit" =~ [Rr] ]]; then
                continue
            elif [[ "$retry_guess_forfeit" =~ [Ff] ]]; then
                incorrect=$(( incorrect + 1 ))
                forfeit=true
                echo
                echo "You forfeited. The file was ${format^^}"
                guesses+=( "Forfeit" )
                trackinfo="$artist - $album - $title"
                tracks_seen+=( "$trackinfo" )
                if [[ "$format" == lossless ]]; then
                    results+=( "Lossless" )
                else
                    results+=( "Lossy" )
                fi
                break
            fi
            if ! "$forfeit"; then
                unset confirmation
                while ! [[ "$confirmation" =~ [Yy] ]]; do
                    echo "Which did you just hear?"
                    while ! guess=$(user_selection "1 for lossless, 2 for lossy: " 1 2); do
                        warn "Invalid selection: '$guess'"
                    done
                    echo "Your selection: $guess"
                    while ! confirmation=$(user_selection "Are you sure? (y/n): " Y y N n); do
                        warn "Invalid selection: '$confirmation'"
                    done
                done
                trackinfo="$artist - $album - $title"
                tracks_seen+=( "$trackinfo" )
                if [[ "$guess" == 1 ]]; then
                    guesses+=( "Lossless" )
                else
                    guesses+=( "Lossy" )
                fi
                if [[ "$format" == lossless ]]; then
                    results+=( "Lossless" )
                else
                    results+=( "Lossy" )
                fi

                echo
                if [[ "$guess" == 1 && "$format" == lossless ]] || [[ "$guess" == 2 && "$format" == lossy ]]; then
                    correct=$(( correct + 1 ))
                    echo "${GREEN}CORRECT!$NOCOLOR The file was ${format^^}"
                else
                    incorrect=$(( incorrect + 1 ))
                    echo "${RED}INCORRECT.$NOCOLOR The file was ${format^^}"
                fi
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
