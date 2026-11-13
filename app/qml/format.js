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
        trackLine: trackLine,
    };
}
