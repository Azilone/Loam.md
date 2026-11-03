import Foundation

extension NaturalDate {
    /// The words for days in English and in one other language, the user's. Only those two: across every language,
    /// short starts would match too much (`ma` is Tuesday in French, Monday in Dutch, tomorrow in Spanish).
    struct Lexicon {
        /// The user's language, `en` when it is English or one Loam does not know.
        let code: String
        /// Word-based days, the user's language first, then English.
        let phrases: [(phrase: String, meaning: Meaning)]
        /// What may come before a count: `in `, `dans `.
        let countPrefixes: [String]
        let units: [(names: [String], component: Calendar.Component, scale: Int)]
        let months: [(names: [String], number: Int)]

        init(_ language: String) {
            let code = String(language.lowercased().prefix { $0 != "-" && $0 != "_" })
            let words = Words.all[code] ?? Words.english
            self.code = Words.all[code] == nil ? "en" : code
            let both = code == "en" ? [words] : [words, Words.english]
            func folded(_ list: [String]) -> [String] { list.map(NaturalDate.normalized) }
            phrases = both.flatMap { language in
                language.phrases.flatMap { names, meaning in folded(names).map { ($0, meaning) } }
                    + language.weekdays.enumerated().flatMap { index, names in
                        folded(names).map { ($0, Meaning.weekday(index + 1)) }
                    }
            }
            countPrefixes = both.flatMap { folded($0.countPrefixes) }.map { $0 + " " }
            units = [
                (both.flatMap { folded($0.days) }, .day, 1),
                (both.flatMap { folded($0.weeks) }, .day, 7),
                (both.flatMap { folded($0.months) }, .month, 1),
            ]
            months = (0..<12).map { index in
                (both.flatMap { $0.monthNames.isEmpty ? [] : folded($0.monthNames[index]) }, index + 1)
            }
        }

        /// The user's first word for `meaning` ("demain"), for titles.
        func word(for meaning: Meaning) -> String? {
            let words = Words.all[code] ?? Words.english
            return words.phrases.first { $0.meaning == meaning }?.names.first
        }
    }

    /// One language's words, written as people write them; they are folded (lowercase, no accents) when used.
    struct Words {
        /// Each meaning's phrases, the usual one first.
        var phrases: [(names: [String], meaning: Meaning)]
        /// Sunday first, as `Calendar` counts.
        var weekdays: [[String]]
        var countPrefixes: [String]
        var days: [String]
        var weeks: [String]
        var months: [String]
        /// January first; empty for languages that write months as numbers (`10月`).
        var monthNames: [[String]]

        static let english = Words(
            phrases: [
                (["today"], .today), (["tomorrow"], .tomorrow), (["yesterday"], .yesterday),
                (["day after tomorrow"], .dayAfterTomorrow), (["next week"], .nextWeek),
                (["this weekend"], .thisWeekend), (["next month"], .nextMonth), (["end of month"], .endOfMonth),
            ],
            weekdays: [["sunday"], ["monday"], ["tuesday"], ["wednesday"], ["thursday"], ["friday"], ["saturday"]],
            countPrefixes: ["in"], days: ["days"], weeks: ["weeks"], months: ["months"],
            monthNames: [
                ["january"], ["february"], ["march"], ["april"], ["may"], ["june"], ["july"], ["august"],
                ["september"], ["october"], ["november"], ["december"],
            ]
        )

        static let all: [String: Words] = [
            "en": english,
            "fr": Words(
                phrases: [
                    (["aujourd'hui"], .today), (["demain"], .tomorrow), (["hier"], .yesterday),
                    (["après-demain"], .dayAfterTomorrow), (["semaine prochaine"], .nextWeek),
                    (["ce week-end"], .thisWeekend), (["mois prochain"], .nextMonth), (["fin du mois"], .endOfMonth),
                ],
                weekdays: [["dimanche"], ["lundi"], ["mardi"], ["mercredi"], ["jeudi"], ["vendredi"], ["samedi"]],
                countPrefixes: ["dans"], days: ["jours"], weeks: ["semaines"], months: ["mois"],
                monthNames: [
                    ["janvier"], ["février"], ["mars"], ["avril"], ["mai"], ["juin"], ["juillet"], ["août"],
                    ["septembre"], ["octobre"], ["novembre"], ["décembre"],
                ]
            ),
            "de": Words(
                phrases: [
                    (["heute"], .today), (["morgen"], .tomorrow), (["gestern"], .yesterday),
                    (["übermorgen"], .dayAfterTomorrow), (["nächste Woche"], .nextWeek),
                    (["dieses Wochenende"], .thisWeekend), (["nächsten Monat", "nächster Monat"], .nextMonth),
                    (["Monatsende", "Ende des Monats"], .endOfMonth),
                ],
                weekdays: [["Sonntag"], ["Montag"], ["Dienstag"], ["Mittwoch"], ["Donnerstag"], ["Freitag"], ["Samstag"]],
                countPrefixes: ["in"], days: ["Tagen", "Tage"], weeks: ["Wochen"], months: ["Monaten", "Monate"],
                monthNames: [
                    ["Januar"], ["Februar"], ["März"], ["April"], ["Mai"], ["Juni"], ["Juli"], ["August"],
                    ["September"], ["Oktober"], ["November"], ["Dezember"],
                ]
            ),
            "es": Words(
                phrases: [
                    (["hoy"], .today), (["mañana"], .tomorrow), (["ayer"], .yesterday),
                    (["pasado mañana"], .dayAfterTomorrow), (["la próxima semana", "próxima semana"], .nextWeek),
                    (["este fin de semana"], .thisWeekend), (["el próximo mes", "próximo mes"], .nextMonth),
                    (["fin de mes"], .endOfMonth),
                ],
                weekdays: [["domingo"], ["lunes"], ["martes"], ["miércoles"], ["jueves"], ["viernes"], ["sábado"]],
                countPrefixes: ["en", "dentro de"], days: ["días"], weeks: ["semanas"], months: ["meses"],
                monthNames: [
                    ["enero"], ["febrero"], ["marzo"], ["abril"], ["mayo"], ["junio"], ["julio"], ["agosto"],
                    ["septiembre"], ["octubre"], ["noviembre"], ["diciembre"],
                ]
            ),
            "it": Words(
                phrases: [
                    (["oggi"], .today), (["domani"], .tomorrow), (["ieri"], .yesterday),
                    (["dopodomani"], .dayAfterTomorrow), (["la prossima settimana", "prossima settimana"], .nextWeek),
                    (["questo weekend", "questo fine settimana"], .thisWeekend),
                    (["il prossimo mese", "prossimo mese"], .nextMonth), (["fine mese"], .endOfMonth),
                ],
                weekdays: [["domenica"], ["lunedì"], ["martedì"], ["mercoledì"], ["giovedì"], ["venerdì"], ["sabato"]],
                countPrefixes: ["tra", "fra"], days: ["giorni"], weeks: ["settimane"], months: ["mesi"],
                monthNames: [
                    ["gennaio"], ["febbraio"], ["marzo"], ["aprile"], ["maggio"], ["giugno"], ["luglio"], ["agosto"],
                    ["settembre"], ["ottobre"], ["novembre"], ["dicembre"],
                ]
            ),
            "nl": Words(
                phrases: [
                    (["vandaag"], .today), (["morgen"], .tomorrow), (["gisteren"], .yesterday),
                    (["overmorgen"], .dayAfterTomorrow), (["volgende week"], .nextWeek),
                    (["dit weekend"], .thisWeekend), (["volgende maand"], .nextMonth),
                    (["einde van de maand", "eind van de maand"], .endOfMonth),
                ],
                weekdays: [["zondag"], ["maandag"], ["dinsdag"], ["woensdag"], ["donderdag"], ["vrijdag"], ["zaterdag"]],
                countPrefixes: ["over"], days: ["dagen"], weeks: ["weken"], months: ["maanden"],
                monthNames: [
                    ["januari"], ["februari"], ["maart"], ["april"], ["mei"], ["juni"], ["juli"], ["augustus"],
                    ["september"], ["oktober"], ["november"], ["december"],
                ]
            ),
            "ar": Words(
                phrases: [
                    (["اليوم"], .today), (["غدا", "غداً", "بكرة"], .tomorrow), (["أمس", "امبارح"], .yesterday),
                    (["بعد غد", "بعد بكرة"], .dayAfterTomorrow), (["الأسبوع القادم", "الأسبوع المقبل"], .nextWeek),
                    (["نهاية هذا الأسبوع", "عطلة نهاية الأسبوع"], .thisWeekend),
                    (["الشهر القادم", "الشهر المقبل"], .nextMonth), (["نهاية الشهر"], .endOfMonth),
                ],
                weekdays: [["الأحد"], ["الاثنين", "الإثنين"], ["الثلاثاء"], ["الأربعاء"], ["الخميس"], ["الجمعة"], ["السبت"]],
                countPrefixes: ["بعد", "خلال"], days: ["أيام", "يوم", "يوما"], weeks: ["أسابيع", "أسبوع"],
                months: ["أشهر", "شهور", "شهر"], monthNames: []
            ),
            "hi": Words(
                phrases: [
                    (["आज"], .today), (["कल"], .tomorrow), (["परसों"], .dayAfterTomorrow),
                    (["अगले हफ्ते", "अगले सप्ताह"], .nextWeek), (["इस सप्ताहांत", "इस वीकेंड"], .thisWeekend),
                    (["अगले महीने"], .nextMonth), (["महीने के अंत", "महीने का अंत"], .endOfMonth),
                ],
                weekdays: [["रविवार"], ["सोमवार"], ["मंगलवार"], ["बुधवार"], ["गुरुवार"], ["शुक्रवार"], ["शनिवार"]],
                countPrefixes: [], days: ["दिन"], weeks: ["हफ्ते", "सप्ताह"], months: ["महीने", "महीना"],
                monthNames: []
            ),
            "ja": Words(
                phrases: [
                    (["今日", "きょう"], .today), (["明日", "あした"], .tomorrow), (["昨日", "きのう"], .yesterday),
                    (["明後日", "あさって"], .dayAfterTomorrow), (["来週"], .nextWeek), (["今週末"], .thisWeekend),
                    (["来月"], .nextMonth), (["月末"], .endOfMonth),
                ],
                weekdays: [["日曜日", "日曜"], ["月曜日", "月曜"], ["火曜日", "火曜"], ["水曜日", "水曜"], ["木曜日", "木曜"],
                           ["金曜日", "金曜"], ["土曜日", "土曜"]],
                countPrefixes: [], days: ["日"], weeks: ["週間", "週"], months: ["ヶ月", "か月", "カ月"], monthNames: []
            ),
            "ko": Words(
                phrases: [
                    (["오늘"], .today), (["내일"], .tomorrow), (["어제"], .yesterday), (["모레"], .dayAfterTomorrow),
                    (["다음 주"], .nextWeek), (["이번 주말"], .thisWeekend), (["다음 달"], .nextMonth), (["월말"], .endOfMonth),
                ],
                weekdays: [["일요일"], ["월요일"], ["화요일"], ["수요일"], ["목요일"], ["금요일"], ["토요일"]],
                countPrefixes: [], days: ["일"], weeks: ["주"], months: ["개월", "달"], monthNames: []
            ),
            "zh": Words(
                phrases: [
                    (["今天"], .today), (["明天"], .tomorrow), (["昨天"], .yesterday), (["后天"], .dayAfterTomorrow),
                    (["下周", "下星期"], .nextWeek), (["这个周末", "本周末"], .thisWeekend), (["下个月"], .nextMonth),
                    (["月底"], .endOfMonth),
                ],
                weekdays: [["星期日", "星期天", "周日"], ["星期一", "周一"], ["星期二", "周二"], ["星期三", "周三"],
                           ["星期四", "周四"], ["星期五", "周五"], ["星期六", "周六"]],
                countPrefixes: [], days: ["天"], weeks: ["周", "星期"], months: ["个月"], monthNames: []
            ),
        ]
    }
}
