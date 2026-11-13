function truncate(text, max) {
    var value = String(text || "");
    if (max <= 0) {
        return "";
    }
    if (value.length <= max) {
        return value;
    }
    return value.slice(0, max - 1) + "…";
}

function formatTime(ms) {
    var total = Math.max(0, Math.floor((ms || 0) / 1000));
    var minutes = Math.floor(total / 60);
    var seconds = total % 60;
    return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
}

function qualityLabel(quality) {
    switch (quality) {
    case "lossless":
        return "FLAC";
    case "hq":
        return "AAC 256";
    case "nq":
        return "AAC 192";
    case "lq":
        return "AAC 64";
    case "cache":
        return "Кэш";
    default:
        return quality;
    }
}

function qualityNext(quality) {
    switch (quality) {
    case "lossless":
        return "hq";
    case "hq":
        return "nq";
    case "nq":
        return "lq";
    case "lq":
        return "lossless";
    default:
        return "lossless";
    }
}

function repeatNext(mode) {
    switch (mode) {
    case "off":
        return "all";
    case "all":
        return "one";
    case "one":
        return "off";
    default:
        return "all";
    }
}

function bytes(value) {
    var n = Number(value || 0);
    if (!isFinite(n) || n < 0) {
        n = 0;
    }
    if (n < 1024) {
        return Math.round(n) + " Б";
    }
    var units = ["КБ", "МБ", "ГБ", "ТБ"];
    var index = -1;
    do {
        n /= 1024;
        index += 1;
    } while (n >= 1024 && index < units.length - 1);
    return (n >= 10 ? Math.round(n) : n.toFixed(1)) + " " + units[index];
}

function trackLine(item) {
    if (!item) {
        return "";
    }
    var artists = item.artists || [];
    var artist = artists.length ? artists[0] : "";
    var title = truncate(item.title || "", artist ? 24 : 44);
    var line = title && artist ? title + " · " + artist : (title || artist);
    return item.cached ? "✓ " + line : line;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        truncate: truncate,
        formatTime: formatTime,
        qualityLabel: qualityLabel,
        qualityNext: qualityNext,
        repeatNext: repeatNext,
        bytes: bytes,
        trackLine: trackLine,
    };
}
