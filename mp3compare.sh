#!/bin/bash

#set -To pipefail
#trap 'echo "+ $LINENO : $BASH_COMMAND" >&2' DEBUG
#set -xo pipefail

errr() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

user_selection() {
    local prompt=$1
    shift
    local options=( "$@" )
    local selection
    read -rn 1 -p "$prompt" selection
    echo >&2
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
    if (( integer_seconds > 59 )); then
        minutes=$(( minutes + 1 ))
        integer_seconds=$(( seconds - 60 ))
    fi
    if (( minutes > 59 )); then
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
    case "$vlc" in
        *vlc.exe)
            local vlc_lossless_clip="$lossless_clip_w"
            local vlc_lossy_clip="$lossy_clip_w"
            ;;
        *vlc)
            local vlc_lossless_clip="$lossless_clip"
            local vlc_lossy_clip="$lossy_clip"
            ;;
    esac

    case "$format" in
        lossless)
            "$vlc" "$vlc_lossless_clip" &>/dev/null || errr "VLC could not play the clip" ;;
        lossy)
            "$vlc" "$vlc_lossy_clip" &>/dev/null || errr "VLC could not play the clip" ;;
    esac
}

select_program() {
    count=1
    local options=()
    numbered "(A) A test (original quality)" && options+=( "A" )
    numbered "(B) B test (${bitrate::-1} kbps lossy)" && options+=( "B" )
    if ! grep -q "no_x_test" <<< "$*"; then
        numbered "(X) X test (unknown)" && options+=( "X" )
    fi
    numbered "(R) Re-clip track" && options+=( "R" )
    if ! grep -q "no_skip" <<< "$*"; then
        numbered "(N) Next track" && options+=( "N" )
    fi
    numbered "(S) Save clip" && options+=( "S" )
    numbered "(Q) Quit" && options+=( "Q" )
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
            if (( randombit )); then
                format=lossless
            else
                format=lossy
            fi
            ;;
        S|s)
            while ! save_choice=$(user_selection "1 for lossless, 2 for lossy:" 1 2); do
                warn "Invalid selection: '$save_choice'"
                echo >&2
            done
            i=1
            save_file_basename=$(sed 's/\//-/g' <<< "$artist -- $album -- $title")
            case "$save_choice" in
                1)
                    while [[ -f "$clips_dir/$save_file_basename -- lossless.$i.wav" ]]; do
                        i=$(( i + 1 ))
                    done
                    if ! cp "$lossless_clip" "$clips_dir/$save_file_basename -- lossless.$i.wav"; then
                        errr "Could not save lossless clip."
                    fi
                    echo "Lossless clip saved to $clips_dir/$save_file_basename -- lossless.$i.wav"
                    ;;
                2)
                    while [[ -f "$clips_dir/$save_file_basename -- lossy.$i.wav" ]]; do
                        i=$(( i + 1 ))
                    done
                    if ! cp "$lossy_clip" "$clips_dir/$save_file_basename -- lossy.$i.wav"; then
                        errr "Could not save lossy clip."
                    fi
                    echo "Lossy clip saved to $clips_dir/$save_file_basename -- lossy.$i.wav"
                    ;;
            esac
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
                echo >&2
            done
            echo
            if [[ "$timestamp_selection" =~ [Uu] ]]; then
                user_timestamps
            else
                if ! random_timestamps; then
                    echo "Something went wrong with random timestamps" >&2
                    break
                fi
            fi
            echo "${startsec}s - ${endsec}s"
            create_clip
            ;;
        *)
            return 1 ;;
    esac
}

numbered() {
    echo "$count. $*"
    count=$(( count + 1 ))
}

create_clip() {
    case "$ffmpeg" in
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

    "$ffmpeg" -loglevel error -y -i "$ffmpeg_track" \
        -ss "$startsec" -t "$clip_duration" "$ffmpeg_lossless_clip" \
        -ss "$startsec" -t "$clip_duration" -b:a "$bitrate" "$tmp_mp3"

    "$ffmpeg" -loglevel error -y -i "$tmp_mp3" "$ffmpeg_lossy_clip"
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
    false
    while (( $? )); do
        read -rp "Start timestamp: " startts
        echo
        startsec=$(parse_timespec_to_seconds "$startts")
    done

    false
    while (( $? )); do
        read -rp "End timestamp: " endts
        echo
        endsec=$(parse_timespec_to_seconds "$endts")
    done

    sanitize_timestamps
}

show_results_and_cleanup() {
    if (( correct + incorrect > 0 )); then
        echo "After $(( correct + incorrect )) trials, your accuracy was:"
        echo "$accuracy%"
        echo "$correct tracks guessed correctly"
    fi
    rm -f "${lossless_clips[@]}" "${lossy_clips[@]}"
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

if [[ -z "$music_dir" || -z "$clips_dir" ]]; then
    errr "You must supply paths to the music and clips dirs."
fi

if [[ ! -d "$music_dir" ]]; then
    errr "'$music_dir' directory does not exist."
fi

if [[ ! -d "$clips_dir" ]]; then
    errr "'$clips_dir' directory does not exist."
fi

commands=( ffmpeg vlc mediainfo ffprobe )
for cmd in "${commands[@]}"; do
    cmd_set="! $cmd=\$(command -v '$cmd.exe') && ! $cmd=\$(command -v '$cmd')"
    if eval "$cmd_set"; then
        errr "'$cmd' was not found"
    fi
done

lossless_clips=()
lossy_clips=()
correct=0
incorrect=0
accuracy=0
trap show_results_and_cleanup EXIT

echo "1. 320 kbps"
echo "2. 256 kbps"
echo "3. 128 kbps"
echo "4. 96 kbps"
echo "5. 64 kbps"
echo "6. 32 kbps"
echo "7. Custom"
echo "8. Quit"
while ! bitrate_selection=$(user_selection "Selection: " $(seq 8)); do
    warn "Invalid selection: '$bitrate_selection'"
    echo >&2
done
case "$bitrate_selection" in
    1)
        bitrate=320k ;;
    2)
        bitrate=256k ;;
    3)
        bitrate=128k ;;
    4)
        bitrate=96k ;;
    5)
        bitrate=64k ;;
    6)
        bitrate=32k ;;
    7)
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
    8)
        exit 0 ;;
    *)
        errr "Input must be between 1 and 8" ;;
esac

while ! random=$(user_selection "Fully random (y/n): " Y y N n); do
    echo "Invalid selection: '$random'"
    echo >&2
done

mapfile -t alltracks < <(find "$music_dir" -type f -iname "*.flac")
#mapfile -t alltracks < <(find "$music_dir" -type f -a \( -iname "*.flac" -o -iname "*.m4a" -o -iname "*.mp3" \))

if (( ${#alltracks[@]} == 0 )); then
    errr "No tracks were found in '$music_dir'"
fi

while true; do
    if ! [[ "$random" =~ [Yy] ]]; then
        read -rp "Track search string: " search_string
    fi
    echo
    if [[ -z "$search_string" ]]; then
        echo "Will choose a random track"
        max=$(( ${#alltracks[@]} - 1 ))
        rand_idx=$(shuf -i 0-"$max" -n 1)
        tracks=( "${alltracks[$rand_idx]}" )
    else
        mapfile -t tracks < <(find "$music_dir" -type f -iname "*$search_string*")
    fi
    if (( ${#tracks[@]} == 0 )); then
        echo "No tracks matched"
        continue
    elif (( ${#tracks[@]} > 10 )); then
        echo "Too many tracks matched"
        continue
    elif (( ${#tracks[@]} > 1 )); then
        echo "Multiple tracks matched: choose the correct track below:"
        for i in "${!tracks[@]}"; do
            echo "$i : ${tracks[$i]}"
        done
        read -rp "Index: " index
        echo
        if [[ -z "$index" || "$index" =~ [^0-9] ]] || (( index >= ${#tracks[@]} )); then
            continue
        fi
        track=${tracks[$index]}
    else
        track=${tracks[0]}
    fi
    track_w=$(wslpath -w "$track")
    case "$ffprobe" in
        *ffprobe.exe)
            ffprobe_track="$track_w" ;;
        *ffprobe)
            ffprobe_track="$track" ;;
    esac
    
    fmt="default=noprint_wrappers=1:nokey=1"
    track_duration=$("$ffprobe" -v error -select_streams a -show_entries stream=duration -of "$fmt" "$ffprobe_track" | sed 's/\r//g')
    track_duration_int=$(grep -Eo "^[0-9]*" <<< "$track_duration")
    echo
    if [[ -z "$search_string" ]]; then
        if ! random_timestamps; then
            errr "Something went wrong with random timestamps"
        fi
    else
        if ! user_timestamps; then
            errr "Something went wrong with user timestamps"
        fi
    fi

    case "$mediainfo" in
        *.exe)
            mediainfo_track="$track_w" ;;
        *)
            mediainfo_track="$track" ;;
    esac
    IFS='|' read -r artist album title < <("$mediainfo" --output="General;%Artist%|%Album%|%Title%" "$mediainfo_track")

    echo "Artist: $artist"
    echo "Album: $album"
    echo "Track: $title"
    echo "${startsec}s - ${endsec}s"

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
        echo
        while ! select_program "${no_skip:+no_skip}"; do
            warn "Invalid selection '$program_selection'"
            echo >&2
        done
        case "$program_selection" in
            A|B|X|a|b|x)
                play_clip ;;
            N|n)
                [[ "$no_skip" ]] || break ;;
            *)
                continue ;;
        esac
        if [[ "$program_selection" =~ [Xx] ]]; then
            forfeit=false
            no_skip=true
            while true; do
                while ! retry_guess_forfeit=$(user_selection "Guess (G), listen again/retry (R), or forfeit (F): " G g R r F f); do
                    warn "Invalid selection: '$retry_guess_forfeit'"
                    echo >&2
                done
                if [[ "$retry_guess_forfeit" =~ [Gg] ]]; then
                    break
                elif [[ "$retry_guess_forfeit" =~ [Rr] ]]; then
                    continue 2
                elif [[ "$retry_guess_forfeit" =~ [Ff] ]]; then
                    incorrect=$(( incorrect + 1 ))
                    forfeit=true
                    echo "You forfeited. The file was ${format^^}"
                    break 2
                fi
            done
            if ! "$forfeit"; then
                unset confirmation
                while ! [[ "$confirmation" =~ [Yy] ]]; do
                    echo "Which did you just hear?"
                    while ! guess=$(user_selection "1 for lossless, 2 for lossy: " 1 2); do
                        warn "Invalid selection: '$guess'"
                        echo >&2
                    done
                    echo "Your selection: $guess"
                    while ! confirmation=$(user_selection "Are you sure? (y/n): " Y y N n); do
                        warn "Invalid selection: '$confirmation'"
                        echo >&2
                    done
                done
                echo
                if [[ "$guess" == 1 && "$format" == lossless ]] || [[ "$guess" == 2 && "$format" == lossy ]]; then
                    correct=$(( correct + 1 ))
                    echo "You guessed correctly! The file was ${format^^}"
                else
                    incorrect=$(( incorrect + 1 ))
                    echo "You guessed incorrectly. The file was ${format^^}"
                fi
            fi
            accuracy=$(bc <<< "100 * $correct / ($correct + $incorrect)")
            echo "Your accuracy is now $accuracy% ($correct/$(( correct + incorrect )))"
            echo
            break
        fi
    done
    while ! [[ "$program_selection" =~ [Nn] ]]; do
        while ! select_program no_x_test; do
            warn "Invalid program selection '$program_selection'"
        done
        case "$program_selection" in
            A|B|a|b)
                play_clip ;;
            *)
                continue ;;
        esac
    done
    rm "$lossless_clip" "$lossy_clip"
done
