import Foundation

extension PublicSuffixList {
    /// The list compiled into the app.
    ///
    /// This is a **curated subset** of publicsuffix.org, not the full list: it
    /// covers the suffixes that appear in App Privacy Report exports in the
    /// launch locales plus the wildcard/exception cases the algorithm must
    /// handle. Hosts under a suffix that is not listed fall back to the
    /// rightmost label and the observation is flagged
    /// `unknown_public_suffix`, so a wrong grouping is visible rather than
    /// silent.
    ///
    /// Only the ICANN section is included. The private section is deliberately
    /// excluded: for owner grouping we want `d1234.cloudfront.net` to roll up to
    /// `cloudfront.net` rather than to become its own registrable domain.
    ///
    /// Replace `bundledVersion`/`bundledRules` from `Rules/source/` at build
    /// time to ship the full list.
    public static let bundledVersion = "psl-subset-2026.08.31"

    public static let bundled = PublicSuffixList(version: bundledVersion, lines: bundledRules)

    public static let bundledRules: [String] = [
        // Reserved names (RFC 2606/6761). Present so the synthetic demo report
        // and test fixtures group correctly without touching a real domain.
        "example", "test", "invalid", "localhost",
        // Generic
        "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "name", "pro",
        "app", "dev", "page", "cloud", "io", "ai", "co", "me", "tv", "cc", "xyz", "online",
        "site", "shop", "store", "tech", "digital", "media", "news", "blog", "email",
        "software", "systems", "network", "services", "solutions", "agency", "life", "world",
        // Country-code, single label
        "ac", "ad", "ae", "af", "ag", "al", "am", "ar", "at", "au", "az", "ba", "be", "bg",
        "bh", "bo", "br", "by", "ca", "ch", "cl", "cn", "cr", "cy", "cz", "de", "dk", "do",
        "dz", "ec", "ee", "eg", "es", "eu", "fi", "fr", "ge", "gr", "gt", "hk", "hn", "hr",
        "hu", "id", "ie", "il", "in", "iq", "ir", "is", "it", "jo", "jp", "ke", "kr", "kw",
        "kz", "lb", "li", "lt", "lu", "lv", "ly", "ma", "md", "mk", "mt", "mx", "my", "ng",
        "nl", "no", "nz", "om", "pa", "pe", "ph", "pk", "pl", "pt", "py", "qa", "ro", "rs",
        "ru", "sa", "se", "sg", "si", "sk", "sv", "th", "tn", "tr", "tw", "ua", "ug", "uk",
        "us", "uy", "uz", "ve", "vn", "za", "zm",
        // Country-code, second level
        "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk", "sch.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "lg.jp",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw",
        "co.kr", "or.kr", "ne.kr", "go.kr", "re.kr", "pe.kr",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "gov.in", "ac.in",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.mx", "org.mx", "net.mx", "gob.mx", "edu.mx",
        "com.ar", "net.ar", "org.ar", "gob.ar", "edu.ar",
        "com.co", "net.co", "org.co", "gov.co", "edu.co",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg",
        "com.my", "net.my", "org.my", "gov.my", "edu.my",
        "com.ph", "net.ph", "org.ph", "gov.ph", "edu.ph",
        "co.th", "in.th", "go.th", "ac.th", "or.th",
        "co.id", "web.id", "or.id", "go.id", "ac.id", "my.id",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr",
        "com.vn", "net.vn", "org.vn", "gov.vn", "edu.vn",
        "com.ua", "net.ua", "org.ua", "gov.ua", "edu.ua",
        "com.ru", "net.ru", "org.ru", "edu.ru", "gov.ru",
        "com.pl", "net.pl", "org.pl", "gov.pl", "edu.pl",
        "com.pt", "gov.pt", "edu.pt",
        "com.es", "org.es", "gob.es", "edu.es",
        "com.gr", "net.gr", "org.gr", "gov.gr", "edu.gr",
        "co.at", "or.at", "ac.at", "gv.at",
        "com.pe", "org.pe", "net.pe", "gob.pe",
        "com.ec", "gob.ec", "edu.ec",
        "com.uy", "gub.uy", "edu.uy",
        "com.sa", "net.sa", "org.sa", "gov.sa", "edu.sa",
        "com.eg", "net.eg", "org.eg", "gov.eg", "edu.eg",
        "com.ng", "net.ng", "org.ng", "gov.ng", "edu.ng",
        "com.pk", "net.pk", "org.pk", "gov.pk", "edu.pk",
        "com.bd", "net.bd", "org.bd", "gov.bd", "edu.bd",
        // Wildcard and exception rules, kept so the algorithm is exercised.
        "*.ck", "!www.ck",
        "*.jm",
        "*.kw",
        "*.mm",
        "*.np",
        "*.pg",
    ]
}
