// V3-E: story-grammar cue detector. Reads one narration line (English,
// Hindi in Devanagari, or romanised Hinglish — usually all three mixed) and
// returns the "cues" a documentary editor reacts to: numbers, dates, places,
// routes, books, articles, quotes, lists, death/hope moods, presenter
// address… Pure Dart, deterministic, no AI.

import '../core/presets/world_map.dart';

/// One thing a line says that a visual pattern can answer.
class Cue {
  final String type;
  final String match; // the words in the line
  final int offset; // character offset in the line
  final double weight; // 0..1 how sure / how strong
  final dynamic value; // parsed value (number, place name, {from,to}…)
  double? at; // seconds, when the line has times

  Cue(this.type, this.match, this.offset, {this.weight = 1, this.value, this.at});

  Map<String, dynamic> toJson() => {
        'type': type,
        'match': match,
        if (value != null) 'value': value,
        if (at != null) 'at': double.parse(at!.toStringAsFixed(2)),
        if (weight != 1) 'weight': double.parse(weight.toStringAsFixed(2)),
      };

  @override
  String toString() => '$type($match${value == null ? '' : '=$value'})';
}

/// Every cue type [CueClassifier.classify] can return.
class CueTypes {
  static const all = [
    'number', 'people_count', 'total_breakdown', 'survivors', 'stat_change', 'comparison', 'gauge',
    'date', 'time', 'day_count', 'duration',
    'place', 'route', 'terrain', 'direction', 'search',
    'book', 'article', 'second_source', 'quote', 'dialogue', 'handwritten', 'archive',
    'list', 'object', 'radio', 'broadcast', 'concept', 'organisation', 'person', 'device', 'technique',
    'dread', 'hope', 'pain', 'witness', 'recap', 'crash', 'lightning', 'snow', 'desert',
    'turning_point', 'emphasis', 'question', 'presenter', 'cta', 'sunrise',
  ];
}

class CueToken {
  final String raw, key;
  final int start, end;
  CueToken(this.raw, this.key, this.start, this.end);
  bool get isDigits => RegExp(r'^\d+$').hasMatch(key);
  bool get latin => RegExp(r'^[a-z0-9]+$').hasMatch(key);
}

class CueClassifier {
  // ------------------------------------------------------------ normalising

  /// Lower case, Devanagari digits → ASCII, nukta / ZWJ removed, chandrabindu
  /// → anusvara, precomposed nukta letters → base letters. 1:1 or dropping.
  static String norm(String s) {
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      if (r == 0x093C || r == 0x200C || r == 0x200D) continue;
      if (r >= 0x0958 && r <= 0x095F) {
        b.writeCharCode(const [0x0915, 0x0916, 0x0917, 0x091C, 0x0921, 0x0922, 0x092B, 0x092F][r - 0x0958]);
        continue;
      }
      if (r == 0x0901) {
        b.writeCharCode(0x0902);
        continue;
      }
      if (r >= 0x0966 && r <= 0x096F) {
        b.writeCharCode(0x30 + r - 0x0966);
        continue;
      }
      b.writeCharCode(r);
    }
    return b.toString();
  }

  /// Romanised spelling fold so Hinglish variants meet: repeated letters
  /// collapse (kitaab → kitab, ummeed → umid), ee → i, oo → u, w → v, z → j, q → k, ph → f.
  static String fold(String s) {
    if (!RegExp(r'^[a-z0-9*]+$').hasMatch(s)) return s;
    final t = s.replaceAll('ph', 'f').replaceAll('w', 'v').replaceAll('z', 'j').replaceAll('q', 'k').replaceAll('ee', 'i').replaceAll('oo', 'u');
    final b = StringBuffer();
    int? last;
    for (final r in t.runes) {
      if (r != last || (r >= 0x30 && r <= 0x39)) b.writeCharCode(r);
      last = r;
    }
    return b.toString();
  }

  static String key(String word) => fold(norm(word));

  static final _word = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

  static List<CueToken> tokens(String line) => [
        for (final m in _word.allMatches(line)) CueToken(m.group(0)!, key(m.group(0)!), m.start, m.end),
      ];

  // ------------------------------------------------------------ lexicon

  /// Strong words per cue type (phrases allowed, "*" = prefix). Matched after
  /// [key] on both sides, so spelling variants (nukta, doubled vowels) meet.
  static const Map<String, List<String>> lexicon = {
    'book': [
      'book', 'books', 'kitab*', 'किताब*', 'pustak', 'पुस्तक', 'novel', 'उपन्यास', 'author', 'lekhak', 'लेखक', 'wrote', 'written',
      'likha', 'likhi', 'likhe', 'लिखा', 'लिखी', 'लिखे', 'published', 'chapter', 'अध्याय', 'memoir', 'biography', 'आत्मकथा',
    ],
    'article': [
      'news', 'न्यूज', 'akhbar', 'अखबार', 'newspaper*', 'report', 'reports', 'रिपोर्ट', 'according to', 'ke mutabik', 'के मुताबिक',
      'ke anusar', 'के अनुसार', 'headline*', 'हेडलाइन', 'article', 'आर्टिकल', 'website', 'वेबसाइट', 'khabar', 'खबर', 'tweet*',
      'ट्वीट', 'magazine', 'journal', 'times', 'post kiya', 'source', 'sources', 'सूत्र*',
    ],
    'second_source': ['podcast*', 'पॉडकास्ट', 'interview*', 'इंटरव्यू', 'साक्षात्कार', 'documentary', 'डॉक्यूमेंट्री', 'talk show', 'baatchit', 'बातचीत'],
    'handwritten': ['letter', 'letters', 'chithi', 'चिट्ठी', 'khat', 'खत', 'patra', 'पत्र', 'note', 'notes', 'नोट', 'handwritten', 'haath se likha', 'हाथ से लिखा', 'diary', 'डायरी', 'parchi', 'पर्ची'],
    'quote': [
      'kaha', 'कहा', 'kahaa', 'bola', 'boli', 'bole', 'बोला', 'बोली', 'बोले', 'said', 'says', 'told', 'bataya', 'बताया', 'pucha', 'पूछा',
      'asked', 'chilaya', 'चिल्लाया', 'shouted', 'replied', 'jawab', 'जवाब', 'quote*',
    ],
    'archive': ['photo', 'photos', 'फोटो', 'tasvir*', 'तस्वीर*', 'archive*', 'purani', 'पुरानी', 'old photo*', 'footage', 'black and white', 'film reel'],
    'object': [
      'radio', 'रेडियो', 'gun', 'bandook', 'बंदूक', 'rifle', 'pistol', 'knife', 'chaku', 'चाकू', 'compass', 'कम्पास', 'watch', 'ghadi', 'घड़ी', 'घडी',
      'naksha', 'नक्शा', 'camera', 'कैमरा', 'phone', 'फोन', 'torch', 'रस्सी', 'rassi', 'rope', 'bottle', 'botal', 'बोतल', 'blanket', 'kambal',
      'कंबल', 'seat', 'seats', 'malba', 'मलबा', 'wreck*', 'wing', 'fuselage', 'axe', 'shoe*', 'joota', 'जूता', 'coat', 'jacket', 'bag', 'बैग',
      'key', 'chabi', 'चाबी', 'ring', 'anguthi', 'अंगूठी', 'passport', 'ticket', 'टिकट', 'cigarette*', 'wallet', 'batua', 'transistor',
    ],
    'radio': [
      'radio', 'रेडियो', 'signal*', 'सिग्नल', 'transmitter', 'mayday', 'sos', 'frequency', 'wireless', 'वायरलेस', 'walkie*', 'morse',
      'transistor', 'beacon',
    ],
    'broadcast': ['broadcast*', 'प्रसारण', 'announcement', 'announced', 'elan', 'ऐलान', 'ghoshna', 'घोषणा', 'news bulletin', 'on air', 'radio par', 'रेडियो पर'],
    'search': [
      'search*', 'talash', 'तलाश', 'khoj*', 'खोज*', 'dhund*', 'ढूंढ*', 'rescue*', 'bachav', 'बचाव', 'helicopter*', 'हेलीकॉप्टर', 'search party',
      'operation', 'ऑपरेशन', 'looking for',
    ],
    'concept': [
      'plan', 'प्लान', 'yojna', 'yojana', 'योजना', 'pact', 'samjhota', 'samjhauta', 'समझौता', 'rule', 'rules', 'niyam', 'नियम', 'kasam', 'कसम',
      'promise*', 'vada', 'वादा', 'deal', 'डील', 'strategy', 'raniti', 'रणनीति', 'faisla', 'फैसला', 'decision', 'idea', 'tarkib', 'तरकीब',
      'mission', 'मिशन', 'shart', 'शर्त', 'oath', 'agreement',
    ],
    'organisation': [
      'team', 'टीम', 'club', 'क्लब', 'army', 'sena', 'सेना', 'company', 'कंपनी', 'organisation', 'organization', 'sangathan', 'संगठन',
      'party', 'पार्टी', 'air force', 'वायुसेना', 'navy', 'नौसेना', 'school', 'college', 'university', 'government', 'sarkar', 'सरकार',
      'agency', 'एजेंसी', 'regiment',
    ],
    'person': [
      'naam', 'नाम', 'named', 'called', 'jinka nam', 'जिनका नाम', 'captain', 'कप्तान', 'pilot', 'पायलट', 'doctor', 'डॉक्टर', 'student*',
      'ladka', 'लड़का', 'ladki', 'लड़की', 'aadmi', 'आदमी', 'aurat', 'औरत', 'player', 'khiladi', 'खिलाड़ी',
    ],
    'device': [
      'chalu', 'चालू', 'band kiya', 'बंद किया', 'band ho', 'बंद हो', 'switched', 'switch', 'turned on', 'turned off', 'engine*', 'इंजन',
      'battery', 'बैटरी', 'generator', 'power', 'पावर', 'start kiya', 'स्टार्ट',
    ],
    'technique': ['trick', 'ट्रिक', 'tarika', 'तरीका', 'technique', 'takneek', 'तकनीक', 'how to', 'kaise kiya', 'कैसे किया', 'method', 'jugaad', 'जुगाड़', 'जुगाड'],
    'dread': [
      'death', 'deaths', 'maut', 'मौत', 'mar gaye', 'mar gaya', 'mar gayi', 'मर गए', 'मर गया', 'मर गई', 'marne', 'मरने', 'mare', 'मरे',
      'died', 'die', 'dead', 'killed', 'laash', 'लाश*', 'shav', 'शव', 'bodies', 'hatya', 'हत्या', 'perished', 'jaan gayi', 'जान गई',
      'hopeless', 'nirasha', 'निराशा', 'despair', 'gave up', 'umid khatam', 'उम्मीद खत्म', 'umid tut', 'उम्मीद टूट', 'akele', 'अकेले',
      'bhukh', 'bhook', 'भूख', 'starv*', 'cannibal*', 'नरभक्ष*', 'darr', 'डर', 'khauf', 'खौफ', 'terror', 'horror', 'tragedy', 'trasdi', 'त्रासदी',
    ],
    'hope': [
      'hope', 'umid', 'उम्मीद', 'asha', 'आशा', 'jinda', 'जिंदा', 'alive', 'surviv*', 'bach gaye', 'बच गए', 'bach gaya', 'बच गया', 'rescued',
      'miracle', 'chamatkar', 'चमत्कार', 'finally', 'akhirkar', 'आखिरकार', 'rahat', 'राहत', 'relief', 'khushi', 'खुशी', 'saved',
    ],
    'pain': [
      'dard', 'दर्द', 'pain', 'cheekh', 'chikh', 'चीख*', 'scream*', 'injur*', 'chot', 'चोट', 'ghayal', 'घायल', 'khoon', 'खून', 'blood',
      'bleeding', 'tadap', 'तड़प', 'तड़प*', 'suffer*', 'broken leg', 'tuti', 'टूटी',
    ],
    'witness': ['dekha', 'देखा', 'dekhi', 'देखी', 'dekhe', 'देखे', 'saw', 'seen', 'witness*', 'gavah', 'गवाह', 'ankhon', 'आंखों', 'eyes', 'najar', 'नजर', 'noticed', 'spotted'],
    'recap': [
      'yaad karo', 'याद करो', 'yad kijiye', 'याद कीजिए', 'yaad hai', 'याद है', 'remember', 'flashback', 'who they were', 'kaun the', 'कौन थे',
      'recap', 'ab tak', 'अब तक', 'pichli bar', 'पिछली बार',
    ],
    'crash': [
      'crash*', 'क्रैश', 'takra*', 'टकरा*', 'gir gaya', 'गिर गया', 'gir gaye', 'गिर गए', 'impact', 'dhamaka', 'धमाका', 'explosion', 'blast',
      'collapse*', 'avalanche', 'हिमस्खलन', 'tut gaya', 'टूट गया', 'shattered', 'smash*',
    ],
    'lightning': ['lightning', 'bijli', 'बिजली', 'thunder', 'garaj', 'गरज', 'toofan', 'tufan', 'तूफान', 'storm', 'blizzard'],
    'snow': [
      'barf', 'बर्फ', 'बर्फीले', 'बर्फीली', 'snow*', 'ice', 'glacier', 'ग्लेशियर', 'andes', 'एंडीज', 'himalaya', 'हिमालय', 'thand', 'ठंड',
      'freez*', 'frozen', 'blizzard', 'avalanche', 'हिमस्खलन', 'minus',
    ],
    'desert': ['registan', 'रेगिस्तान', 'desert', 'sand', 'ret', 'रेत', 'sahara', 'dune*', 'thar', 'थार'],
    'terrain': [
      'andes', 'एंडीज', 'himalaya', 'हिमालय', 'alps', 'pahad', 'पहाड़', 'पहाड', 'पहाड़ों', 'पहाडों', 'pahadon', 'mountain*', 'parvat', 'पर्वत',
      'range', 'peak', 'choti', 'चोटी', 'nadi', 'नदी', 'river*', 'ghati', 'घाटी', 'valley', 'glacier', 'ग्लेशियर', 'border', 'sima', 'सीमा',
      'sarhad', 'सरहद', 'jungle', 'जंगल', 'forest', 'samundar', 'समुंदर', 'samudra', 'समुद्र', 'sea', 'ocean', 'volcano', 'jvalamukhi',
    ],
    'direction': [
      'north', 'south', 'east', 'west', 'uttar', 'dakshin', 'purab', 'purv', 'paschim', 'pashchim', 'उत्तर', 'दक्षिण', 'पूर्व', 'पश्चिम',
      'direction', 'disha', 'दिशा', 'kis taraf', 'किस तरफ', 'which way', 'baen', 'बाएं', 'daen', 'दाएं',
    ],
    'turning_point': [
      'lekin phir', 'लेकिन फिर', 'but then', 'suddenly', 'achanak', 'अचानक', 'tabhi', 'तभी', 'aur phir', 'और फिर', 'everything changed',
      'sab badal', 'सब बदल', 'twist',
    ],
    'emphasis': [
      'sabse', 'सबसे', 'biggest', 'never', 'kabhi nahi', 'कभी नहीं', 'shocking', 'hairan', 'हैरान', 'unbelievable', 'yakin', 'यकीन',
      'impossible', 'namumkin', 'नामुमकिन', 'only', 'sirf', 'सिर्फ', 'imagine', 'socho', 'सोचो',
    ],
    'presenter': [
      'aap', 'आप', 'apko', 'आपको', 'apne', 'आपने', 'aapke', 'आपके', 'dosto', 'doston', 'दोस्तों', 'दोस्तो', 'you', 'your', 'socho', 'सोचो',
      'sochiye', 'सोचिए', 'imagine', 'kya aap', 'क्या आप', 'batao', 'बताओ', 'bataiye', 'बताइए', 'guys',
    ],
    'cta': [
      'subscribe', 'सब्सक्राइब', 'लाइक', 'शेयर', 'comment*', 'कमेंट', 'जॉइन', 'whatsapp', 'व्हाट्सएप', 'telegram', 'instagram',
      'channel', 'चैनल', 'bell icon', 'join karo', 'join kijiye',
    ],
    'sunrise': ['subah', 'सुबह', 'sunrise', 'suraj', 'सूरज', 'sun', 'dhoop', 'धूप', 'sunlight', 'new day', 'nayi subah', 'नई सुबह', 'roshni', 'रोशनी'],
    'stat_change': [
      'badh*', 'बढ़*', 'बढ*', 'increased', 'rose', 'grew', 'ghat*', 'घट*', 'decreased', 'dropped', 'fell', 'kam ho', 'कम हो', 'reduced',
      'doubled', 'dugna', 'दुगना', 'halved',
    ],
    'comparison': ['lekin', 'लेकिन', 'but', 'vs', 'versus', 'compared', 'jabki', 'जबकि', 'whereas', 'mukable', 'मुकाबले', 'tulna', 'तुलना', 'while'],
    'survivors': ['survivor*', 'bache', 'बचे', 'jinda bache', 'जिंदा बचे', 'casualt*', 'mare gaye', 'मारे गए', 'zinda', 'dead and alive'],
    'gauge': ['feet', 'फीट', 'ft', 'altitude', 'unchai', 'ऊंचाई', 'height', 'speed', 'raftar', 'रफ्तार', 'gahrai', 'गहराई', 'depth', 'knots', 'mph'],
    'question': ['kya', 'क्या', 'kyun', 'kyon', 'क्यों', 'kaise', 'कैसे', 'why', 'how', 'what', 'kaun', 'कौन', 'kitne', 'कितने'],
  };

  /// Words that only hint (half weight).
  static const Map<String, List<String>> weak = {
    'place': ['shahar', 'शहर', 'city', 'desh', 'देश', 'country', 'gaon', 'gaanv', 'गांव', 'गाँव', 'village', 'ilaka', 'इलाका', 'region', 'kshetra', 'क्षेत्र'],
    'route': [
      'flew', 'udan', 'उड़ान', 'उडान', 'ude', 'उड़े', 'gaye', 'गए', 'went', 'travel*', 'safar', 'सफर', 'yatra', 'यात्रा', 'journey', 'nikle',
      'निकले', 'set off', 'pahunche', 'पहुंचे', 'reached', 'walked', 'chale', 'चले', 'trek*', 'flight', 'फ्लाइट', 'ja rahe', 'ja raha', 'ja rahi', 'जा रहे', 'जा रहा', 'जा रही', 'udd', 'उड़',
    ],
    'time': ['subah', 'सुबह', 'morning', 'sham', 'शाम', 'evening', 'raat', 'रात', 'night', 'dopahar', 'दोपहर', 'noon', 'midnight', 'aadhi raat', 'आधी रात'],
    'people_count': ['log', 'लोग', 'people', 'passengers', 'yatri', 'यात्री', 'players', 'crew', 'khiladi', 'खिलाड़ी', 'members', 'sadasya', 'सदस्य'],
  };

  // Units
  static const _durationUnitsRaw = {
    'din': 'days', 'दिन': 'days', 'day': 'days', 'days': 'days', 'hafte': 'weeks', 'हफ्ते': 'weeks', 'hafta': 'weeks', 'हफ्ता': 'weeks',
    'week': 'weeks', 'weeks': 'weeks', 'mahine': 'months', 'महीने': 'months', 'mahina': 'months', 'महीना': 'months', 'month': 'months',
    'months': 'months', 'ghante': 'hours', 'घंटे': 'hours', 'ghanta': 'hours', 'घंटा': 'hours', 'hour': 'hours', 'hours': 'hours',
    'minute': 'minutes', 'minutes': 'minutes', 'mins': 'minutes', 'min': 'minutes', 'minat': 'minutes', 'मिनट': 'minutes',
    'second': 'seconds', 'seconds': 'seconds', 'सेकंड': 'seconds', 'saal': 'years', 'साल': 'years', 'years': 'years', 'baras': 'years', 'बरस': 'years',
  };
  static const _statUnitsRaw = {
    '%': '%', 'percent': '%', 'pratishat': '%', 'प्रतिशत': '%', 'fisadi': '%', 'फीसदी': '%', 'km': 'KM', 'kilometer': 'KM', 'kilometre': 'KM',
    'किलोमीटर': 'KM', 'meter': 'M', 'metre': 'M', 'मीटर': 'M', 'feet': 'FT', 'फीट': 'FT', 'ft': 'FT', 'kg': 'KG', 'kilo': 'KG', 'किलो': 'KG',
    'ton': 'TONS', 'tons': 'TONS', 'rupees': '₹', 'rupaye': '₹', 'रुपये': '₹', 'rs': '₹', 'dollar': '\$', 'dollars': '\$', 'डॉलर': '\$',
    'crore': 'CRORE', 'करोड़': 'CRORE', 'करोड': 'CRORE', 'karod': 'CRORE', 'lakh': 'LAKH', 'लाख': 'LAKH', 'million': 'MILLION',
    'billion': 'BILLION', 'hajar': 'THOUSAND', 'हजार': 'THOUSAND', 'thousand': 'THOUSAND',
  };
  static const _scaleRaw = {'crore': 1e7, 'करोड': 1e7, 'karod': 1e7, 'lakh': 1e5, 'लाख': 1e5, 'million': 1e6, 'billion': 1e9, 'hajar': 1e3, 'हजार': 1e3, 'thousand': 1e3, 'sau': 100.0, 'सौ': 100.0, 'hundred': 100.0};
  static const _numberWordsRaw = {
    'do': 2, 'दो': 2, 'two': 2, 'tin': 3, 'तीन': 3, 'three': 3, 'char': 4, 'चार': 4, 'four': 4, 'panch': 5, 'पांच': 5, 'five': 5,
    'chhe': 6, 'chah': 6, 'छह': 6, 'six': 6, 'sat': 7, 'सात': 7, 'seven': 7, 'ath': 8, 'आठ': 8, 'eight': 8, 'nau': 9, 'नौ': 9, 'nine': 9,
    'das': 10, 'दस': 10, 'ten': 10, 'bis': 20, 'बीस': 20, 'twenty': 20, 'tis': 30, 'तीस': 30, 'thirty': 30, 'pachas': 50, 'पचास': 50,
    'fifty': 50, 'sau': 100, 'सौ': 100, 'hundred': 100, 'hajar': 1000, 'हजार': 1000, 'thousand': 1000,
  };
  static const monthsRaw = {
    'january': 1, 'jan': 1, 'जनवरी': 1, 'february': 2, 'feb': 2, 'फरवरी': 2, 'march': 3, 'मार्च': 3, 'april': 4, 'apr': 4, 'अप्रैल': 4,
    'may': 5, 'मई': 5, 'june': 6, 'jun': 6, 'जून': 6, 'july': 7, 'jul': 7, 'जुलाई': 7, 'august': 8, 'aug': 8, 'अगस्त': 8,
    'september': 9, 'sep': 9, 'sept': 9, 'सितंबर': 9, 'सितम्बर': 9, 'october': 10, 'oct': 10, 'अक्टूबर': 10, 'november': 11, 'nov': 11,
    'नवंबर': 11, 'नवम्बर': 11, 'december': 12, 'dec': 12, 'दिसंबर': 12, 'दिसम्बर': 12,
  };
  static const weekdaysRaw = {
    'monday': 'MONDAY', 'somvar': 'MONDAY', 'सोमवार': 'MONDAY', 'tuesday': 'TUESDAY', 'mangalvar': 'TUESDAY', 'मंगलवार': 'TUESDAY',
    'wednesday': 'WEDNESDAY', 'budhvar': 'WEDNESDAY', 'बुधवार': 'WEDNESDAY', 'thursday': 'THURSDAY', 'guruvar': 'THURSDAY', 'गुरुवार': 'THURSDAY',
    'friday': 'FRIDAY', 'shukravar': 'FRIDAY', 'शुक्रवार': 'FRIDAY', 'saturday': 'SATURDAY', 'shanivar': 'SATURDAY', 'शनिवार': 'SATURDAY',
    'sunday': 'SUNDAY', 'ravivar': 'SUNDAY', 'itvar': 'SUNDAY', 'रविवार': 'SUNDAY', 'इतवार': 'SUNDAY',
  };

  static Map<String, V> _rekey<V>(Map<String, V> m) => {for (final e in m.entries) key(e.key): e.value};
  static final _durationUnits = _rekey(_durationUnitsRaw);
  static final _statUnits = _rekey(_statUnitsRaw);
  static final _scale = _rekey(_scaleRaw);
  static final _numberWords = _rekey(_numberWordsRaw);
  static final months = _rekey(monthsRaw);
  static final weekdays = _rekey(weekdaysRaw);

  /// Hindi / Hinglish country names → a WorldMap query.
  static const countryNames = {
    'भारत': 'India', 'हिंदुस्तान': 'India', 'bharat': 'India', 'hindustan': 'India', 'पाकिस्तान': 'Pakistan', 'चीन': 'China', 'chin': 'China',
    'अमेरिका': 'USA', 'amerika': 'USA', 'amrika': 'USA', 'america': 'USA', 'रूस': 'Russia', 'rus': 'Russia', 'जापान': 'Japan', 'नेपाल': 'Nepal',
    'भूटान': 'Bhutan', 'बांग्लादेश': 'Bangladesh', 'श्रीलंका': 'Sri Lanka', 'अफगानिस्तान': 'Afghanistan', 'ईरान': 'Iran', 'इराक': 'Iraq',
    'इजराइल': 'Israel', 'सऊदी अरब': 'Saudi Arabia', 'तुर्की': 'Turkey', 'मिस्र': 'Egypt', 'misr': 'Egypt', 'चिली': 'Chile', 'अर्जेंटीना': 'Argentina',
    'उरुग्वे': 'Uruguay', 'ब्राजील': 'Brazil', 'पेरू': 'Peru', 'मेक्सिको': 'Mexico', 'कनाडा': 'Canada', 'फ्रांस': 'France', 'जर्मनी': 'Germany',
    'इटली': 'Italy', 'स्पेन': 'Spain', 'इंग्लैंड': 'GBR', 'ब्रिटेन': 'GBR', 'england': 'GBR', 'britain': 'GBR', 'यूक्रेन': 'Ukraine',
    'ऑस्ट्रेलिया': 'Australia', 'दक्षिण अफ्रीका': 'South Africa', 'उत्तर कोरिया': 'North Korea', 'दक्षिण कोरिया': 'South Korea',
    'वियतनाम': 'Vietnam', 'थाईलैंड': 'Thailand', 'इंडोनेशिया': 'Indonesia', 'म्यांमार': 'Myanmar', 'मालदीव': 'Maldives', 'क्यूबा': 'Cuba',
    'वेनेजुएला': 'Venezuela', 'कोलंबिया': 'Colombia', 'बोलीविया': 'Bolivia', 'पैराग्वे': 'Paraguay', 'न्यूजीलैंड': 'New Zealand',
  };

  /// City spelling (English / Hindi / Hinglish) → "City|Country" (country = WorldMap query).
  static const cities = {
    'delhi': 'Delhi|India', 'dilli': 'Delhi|India', 'दिल्ली': 'Delhi|India', 'mumbai': 'Mumbai|India', 'bombay': 'Mumbai|India',
    'मुंबई': 'Mumbai|India', 'kolkata': 'Kolkata|India', 'कोलकाता': 'Kolkata|India', 'chennai': 'Chennai|India', 'चेन्नई': 'Chennai|India',
    'bengaluru': 'Bengaluru|India', 'bangalore': 'Bengaluru|India', 'बेंगलुरु': 'Bengaluru|India', 'pune': 'Pune|India', 'पुणे': 'Pune|India',
    'jaipur': 'Jaipur|India', 'जयपुर': 'Jaipur|India', 'alwar': 'Alwar|India', 'अलवर': 'Alwar|India', 'agra': 'Agra|India',
    'आगरा': 'Agra|India', 'lucknow': 'Lucknow|India', 'लखनऊ': 'Lucknow|India', 'hyderabad': 'Hyderabad|India', 'हैदराबाद': 'Hyderabad|India',
    'karachi': 'Karachi|Pakistan', 'कराची': 'Karachi|Pakistan', 'lahore': 'Lahore|Pakistan', 'लाहौर': 'Lahore|Pakistan', 'islamabad': 'Islamabad|Pakistan',
    'इस्लामाबाद': 'Islamabad|Pakistan', 'kabul': 'Kabul|Afghanistan', 'काबुल': 'Kabul|Afghanistan', 'dhaka': 'Dhaka|Bangladesh', 'ढाका': 'Dhaka|Bangladesh',
    'kathmandu': 'Kathmandu|Nepal', 'काठमांडू': 'Kathmandu|Nepal', 'london': 'London|GBR', 'लंदन': 'London|GBR', 'paris': 'Paris|France',
    'पेरिस': 'Paris|France', 'new york': 'New York|USA', 'न्यूयॉर्क': 'New York|USA', 'washington': 'Washington|USA', 'वॉशिंगटन': 'Washington|USA',
    'moscow': 'Moscow|Russia', 'मॉस्को': 'Moscow|Russia', 'tokyo': 'Tokyo|Japan', 'टोक्यो': 'Tokyo|Japan', 'beijing': 'Beijing|China',
    'बीजिंग': 'Beijing|China', 'dubai': 'Dubai|UAE', 'दुबई': 'Dubai|UAE', 'santiago': 'Santiago|Chile', 'सैंटियागो': 'Santiago|Chile',
    'सेंटियागो': 'Santiago|Chile', 'mendoza': 'Mendoza|Argentina', 'मेंडोजा': 'Mendoza|Argentina', 'montevideo': 'Montevideo|Uruguay', 'मोंटेवीडियो': 'Montevideo|Uruguay',
    'buenos aires': 'Buenos Aires|Argentina', 'ब्यूनस आयर्स': 'Buenos Aires|Argentina', 'berlin': 'Berlin|Germany', 'बर्लिन': 'Berlin|Germany', 'rome': 'Rome|Italy',
    'रोम': 'Rome|Italy', 'madrid': 'Madrid|Spain', 'sydney': 'Sydney|Australia', 'सिडनी': 'Sydney|Australia', 'cairo': 'Cairo|Egypt',
    'काहिरा': 'Cairo|Egypt', 'tehran': 'Tehran|Iran', 'तेहरान': 'Tehran|Iran', 'baghdad': 'Baghdad|Iraq', 'बगदाद': 'Baghdad|Iraq',
    'istanbul': 'Istanbul|Turkey', 'इस्तांबुल': 'Istanbul|Turkey', 'curico': 'Curico|Chile', 'malargue': 'Malargue|Argentina',
  };

  /// English country names that are also everyday words / names.
  static const _countryStop = {'chad', 'mali', 'togo', 'jordan', 'georgia', 'guinea', 'turkey', 'niger', 'oman'};

  // ------------------------------------------------------------ compiled lexicon

  static final Map<String, List<List<String>>> _compiled = {};

  static List<List<String>> _phrases(List<String> words) => [
        for (final w in words)
          [for (final p in w.split(' ')) if (p.isNotEmpty) p.endsWith('*') ? '${key(p.substring(0, p.length - 1))}*' : key(p)],
      ];

  static List<List<String>> _lex(String type, Map<String, List<String>> from) =>
      _compiled.putIfAbsent('${identityHashCode(from)}:$type', () => _phrases(from[type] ?? const []));

  static bool _tokMatch(String tok, String pat) =>
      pat.endsWith('*') ? tok.startsWith(pat.substring(0, pat.length - 1)) && tok.length > 1 : tok == pat;

  /// (start token, token count) of every phrase of [phrases] in [toks].
  static List<(int, int)> findPhrases(List<CueToken> toks, List<List<String>> phrases) {
    final out = <(int, int)>[];
    for (int i = 0; i < toks.length; i++) {
      for (final ph in phrases) {
        if (ph.isEmpty || i + ph.length > toks.length) continue;
        var ok = true;
        for (int j = 0; j < ph.length; j++) {
          if (!_tokMatch(toks[i + j].key, ph[j])) {
            ok = false;
            break;
          }
        }
        if (ok) out.add((i, ph.length));
      }
    }
    return out;
  }

  /// True when any of [words] (phrases, "*" prefix) is in [line].
  static bool mentions(String line, List<String> words) => findPhrases(tokens(line), _phrases(words)).isNotEmpty;

  // ------------------------------------------------------------ places

  static List<(List<String>, String)>? _placeCache;
  static int _placeCacheFor = -1;

  /// (token keys, display name) for every country (WorldMap when loaded),
  /// the Hindi/Hinglish names and the city list.
  static List<(List<String>, String)> _places() {
    final n = WorldMap.countries.length;
    if (_placeCache != null && _placeCacheFor == n) return _placeCache!;
    final out = <(List<String>, String)>[];
    String display(String q) => WorldMap.find(q)?.name ?? q;
    for (final c in WorldMap.countries) {
      final k = [for (final t in tokens(c.name)) t.key];
      if (k.isEmpty || (k.length == 1 && _countryStop.contains(k.first))) continue;
      out.add((k, c.name));
    }
    for (final e in countryNames.entries) {
      out.add(([for (final t in tokens(e.key)) t.key], display(e.value)));
    }
    if (WorldMap.countries.isEmpty) {
      for (final name in const [
        'India', 'Pakistan', 'Chile', 'Argentina', 'Uruguay', 'Brazil', 'Peru', 'Bolivia', 'Paraguay', 'Russia', 'Japan', 'Nepal',
        'Afghanistan', 'Iran', 'Iraq', 'Israel', 'Egypt', 'France', 'Germany', 'Italy', 'Spain', 'Canada', 'Mexico', 'Australia',
        'Ukraine', 'Vietnam', 'Bangladesh', 'Sri Lanka', 'United Kingdom', 'United States',
      ]) {
        out.add(([for (final t in tokens(name)) t.key], name));
      }
    }
    for (final e in cities.entries) {
      final parts = e.value.split('|');
      out.add(([for (final t in tokens(e.key)) t.key], 'city:${parts[0]}|${display(parts[1])}'));
    }
    out.sort((a, b) => b.$1.length.compareTo(a.$1.length)); // longest first
    _placeCacheFor = n;
    return _placeCache = out;
  }

  // ------------------------------------------------------------ classify

  /// The cues of one line. With [start]/[end] each cue gets an estimated
  /// time ("at") from its character position.
  static List<Cue> classify(String line, {double? start, double? end}) {
    final toks = tokens(line);
    final cues = <Cue>[];
    final used = <int>{}; // tokens consumed by numbers/dates/places
    String span(int i, int n) => line.substring(toks[i].start, toks[i + n - 1].end);
    final keys = [for (final t in toks) t.key];

    // --- times: 3:21 / 3.21 pm / 5 pm / 5 baje
    final dl = String.fromCharCodes([for (final u in line.codeUnits) u >= 0x0966 && u <= 0x096F ? 0x30 + u - 0x0966 : u]);
    void time(int from, int to, String value) {
      final idx = toks.indexWhere((t) => t.end > from);
      if (idx < 0 || used.contains(idx)) return;
      for (int k = 0; k < toks.length; k++) {
        if (toks[k].start < to && toks[k].end > from) used.add(k);
      }
      cues.add(Cue('time', line.substring(from, to).trim(), toks[idx].start, value: value));
    }

    String ampm(String? s) => s == null ? '' : ' ${s.replaceAll('.', '').toUpperCase()}';
    for (final m in RegExp(r'(?<!\d)(\d{1,2}):(\d{2})(?:\s*(am|pm|a\.m\.|p\.m\.)(?![a-z]))?', caseSensitive: false).allMatches(dl)) {
      time(m.start, m.end, '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}${ampm(m.group(3))}');
    }
    for (final m in RegExp(r'(?<!\d)(\d{1,2})(?:\.(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?![a-z])', caseSensitive: false).allMatches(dl)) {
      time(m.start, m.end, '${m.group(1)!.padLeft(2, '0')}:${m.group(2) ?? '00'}${ampm(m.group(3))}');
    }
    for (int i = 0; i + 1 < toks.length; i++) {
      if (toks[i].isDigits && (toks[i + 1].key == 'baje' || toks[i + 1].key == 'बजे') && !used.contains(i)) {
        time(toks[i].start, toks[i + 1].end, '${toks[i].key.padLeft(2, '0')}:00');
      }
    }

    // --- numbers, years, durations, day counts, units
    for (int i = 0; i < toks.length; i++) {
      if (used.contains(i)) continue;
      final k = keys[i];
      final digits = RegExp(r'^(\d+)').firstMatch(k);
      double? value;
      if (digits != null) {
        // "1,20,000" / "3.5" are split by the tokenizer: join digit groups.
        var j = i;
        var text = toks[i].raw;
        var numStr = digits.group(1)!;
        while (j + 1 < toks.length && toks[j + 1].isDigits && RegExp(r'^[,.]$').hasMatch(line.substring(toks[j].end, toks[j + 1].start))) {
          final sep = line.substring(toks[j].end, toks[j + 1].start);
          numStr += sep == ',' ? toks[j + 1].key : '.${toks[j + 1].key}';
          text = line.substring(toks[i].start, toks[j + 1].end);
          j++;
        }
        for (int q = i + 1; q <= j; q++) {
          used.add(q);
        }
        value = double.tryParse(numStr);
        if (value == null) continue;
        final suffix = k.substring(digits.group(1)!.length); // "61वें", "61st", "5km"
        final next = j + 1 < toks.length ? keys[j + 1] : '';
        final prev = i > 0 ? keys[i - 1] : '';
        // Day count: "day 61", "दिन 61", "61वें दिन", "61st day"
        final ordinal = RegExp(r'^(st|nd|rd|th|वें|वे|वां|वीं|ve|ven|van|vi)$').hasMatch(suffix);
        if (prev == 'day' || prev == 'दिन' || prev == 'din' || (ordinal && (_durationUnits[next] == 'days'))) {
          used.add(i);
          if (_durationUnits[next] == 'days') used.add(j + 1);
          cues.add(Cue('day_count', ordinal ? '$text ${j + 1 < toks.length ? toks[j + 1].raw : ''}'.trim() : '${toks[i - (prev.isEmpty ? 0 : 1)].raw} $text', toks[i].start,
              value: 'DAY ${value.round()}'));
          continue;
        }
        // Day of the month next to a month name: part of the date
        if (value >= 1 && value <= 31 && (months.containsKey(next) || months.containsKey(prev))) {
          used.add(i);
          continue;
        }
        // Year
        if (suffix.isEmpty && value >= 1000 && value <= 2100 && value == value.roundToDouble() && !_statUnits.containsKey(next) && _durationUnits[next] == null) {
          used.add(i);
          cues.add(Cue('date', text, toks[i].start, value: _dateAround(toks, keys, i, value.round())));
          continue;
        }
        // Duration: "8 din", "72 days", "11 mins", "2 hafte"
        final unit = _durationUnits[suffix] ?? _durationUnits[next];
        if (unit != null) {
          used.add(i);
          if (_durationUnits[next] != null) used.add(j + 1);
          cues.add(Cue('duration', _durationUnits[next] != null ? '$text ${toks[j + 1].raw}' : text, toks[i].start,
              value: {'value': value, 'unit': unit}));
          continue;
        }
        // Scale + unit: "45 लाख", "60 km", "3 करोड़ रुपये", "70%", "₹500"
        var v = value;
        var n = j;
        final units = <String>[];
        final sfxScale = _scale[suffix];
        if (sfxScale != null) {
          v *= sfxScale;
          if (_statUnits[suffix] != null) units.add(_statUnits[suffix]!);
        } else if (_statUnits[suffix] != null) {
          units.add(_statUnits[suffix]!);
        }
        if (n + 1 < toks.length && _scale[keys[n + 1]] != null) {
          v *= _scale[keys[n + 1]]!;
          n++;
          if (_statUnits[keys[n]] != null) units.add(_statUnits[keys[n]]!);
        }
        if (n + 1 < toks.length && _statUnits[keys[n + 1]] != null) {
          n++;
          units.add(_statUnits[keys[n]]!);
        }
        final after = line.substring(toks[n].end, (toks[n].end + 2).clamp(0, line.length));
        if (after.trimLeft().startsWith('%') && !units.contains('%')) units.add('%');
        final before = toks[i].start > 0 ? line.substring(toks[i].start - 1, toks[i].start) : '';
        if ((before == '₹' || before == '\$') && !units.contains(before)) units.add(before);
        for (int q = i; q <= n; q++) {
          used.add(q);
        }
        final currency = units.where((u) => u == '₹' || u == '\$').join();
        final rest = units.where((u) => u != '₹' && u != '\$' && u != '%').join(' ');
        final display = '$currency${_fmt(value)}${units.contains('%') ? '%' : ''}${rest.isEmpty ? '' : ' $rest'}';
        final unitLabel = units.join(' ');
        cues.add(Cue('number', line.substring(toks[i].start, toks[n].end), toks[i].start, value: {'value': v, 'text': display, 'unit': unitLabel}));
        // people after the number → people_count
        final pi = n + 1 < toks.length ? n + 1 : -1;
        if (pi >= 0 && findPhrases([toks[pi]], _lex('people_count', weak)).isNotEmpty) {
          cues.add(Cue('people_count', '$text ${toks[pi].raw}', toks[i].start, value: {'value': v, 'label': toks[pi].raw.toUpperCase()}));
        }
        // gauge: number + ft/feet/altitude/speed
        if (units.contains('FT') || (units.contains('M') && findPhrases(toks, _lex('gauge', lexicon)).isNotEmpty)) {
          cues.add(Cue('gauge', text, toks[i].start, value: {'value': v, 'unit': unitLabel}));
        }
        continue;
      }
      // Number words only count with a unit / scale / people after them ("teen din", "do lakh log").
      final nw = _numberWords[k];
      if (nw != null && i + 1 < toks.length) {
        final next = keys[i + 1];
        final unit = _durationUnits[next];
        if (unit != null) {
          used..add(i)..add(i + 1);
          cues.add(Cue('duration', span(i, 2), toks[i].start, value: {'value': nw.toDouble(), 'unit': unit}, weight: 0.9));
        } else if (_scale.containsKey(next) || _statUnits.containsKey(next)) {
          used..add(i)..add(i + 1);
          final v = nw * (_scale[next] ?? 1);
          cues.add(Cue('number', span(i, 2), toks[i].start, value: {'value': v, 'text': '${_fmt(nw.toDouble())} ${_statUnits[next] ?? ''}'.trim(), 'unit': _statUnits[next] ?? ''}, weight: 0.8));
        } else if (findPhrases([toks[i + 1]], _lex('people_count', weak)).isNotEmpty) {
          used..add(i)..add(i + 1);
          cues.add(Cue('people_count', span(i, 2), toks[i].start, value: {'value': nw.toDouble(), 'label': toks[i + 1].raw.toUpperCase()}, weight: 0.8));
        }
      }
    }

    // --- months / weekdays (dates without a year)
    for (int i = 0; i < toks.length; i++) {
      if (used.contains(i)) continue;
      final k = keys[i];
      final mo = months[k];
      if (mo != null) {
        final near = [for (int d = -2; d <= 2; d++) if (d != 0 && i + d >= 0 && i + d < toks.length) toks[i + d]];
        final hasNum = near.any((t) => RegExp(r'^\d').hasMatch(t.key));
        final devanagari = !toks[i].latin;
        if (!hasNum && (k == 'may' || k == 'march' || k.length <= 3) && !devanagari) continue;
        used.add(i);
        cues.add(Cue('date', toks[i].raw, toks[i].start, value: _dateAround(toks, keys, i, null), weight: hasNum ? 1 : 0.7));
        continue;
      }
      final wd = weekdays[k];
      if (wd != null) {
        used.add(i);
        cues.add(Cue('date', toks[i].raw, toks[i].start, value: wd, weight: 0.8));
      }
      if (k == 'तारीख' || k == 'tarikh' || k == 'date') cues.add(Cue('date', toks[i].raw, toks[i].start, weight: 0.5));
    }

    // --- "kitne din / how many days / how long" (duration question)
    for (final (i, n) in findPhrases(toks, _phrases(const ['kitne din', 'कितने दिन', 'how many days', 'how long', 'kitna samay', 'कितना समय', 'kitne mahine', 'कितने महीने', 'kitne ghante', 'कितने घंटे']))) {
      cues.add(Cue('duration', span(i, n), toks[i].start, value: {'question': true}, weight: 1));
    }

    // --- places
    final places = <String>[];
    final countries = <String>[];
    final placeTok = <int, String>{};
    for (final (k, name) in _places()) {
      for (final (i, n) in findPhrases(toks, [k])) {
        if (Iterable<int>.generate(n, (x) => i + x).any((x) => used.contains(x) || placeTok.containsKey(x))) continue;
        for (int x = i; x < i + n; x++) {
          placeTok[x] = name;
        }
        final isCity = name.startsWith('city:');
        final display = isCity ? name.substring(5).split('|').first : name;
        final country = isCity ? name.split('|').last : name;
        if (!places.contains(display)) places.add(display);
        if (!countries.contains(country)) countries.add(country);
        cues.add(Cue('place', span(i, n), toks[i].start, value: {'name': display, 'country': country, if (isCity) 'city': true}));
      }
    }
    for (final (i, n) in findPhrases(toks, _lex('place', weak))) {
      if (!placeTok.containsKey(i)) cues.add(Cue('place', span(i, n), toks[i].start, weight: 0.4));
    }

    // --- routes: "X se Y tak", "X से Y तक", "from X to Y"
    final route = _route(toks, keys, placeTok, line);
    if (route != null) {
      cues.add(Cue('route', route.$3, route.$4, value: {'from': route.$1, 'to': route.$2}));
    } else {
      final journey = findPhrases(toks, _lex('route', weak));
      if (journey.isNotEmpty && countries.length >= 2) {
        final (i, n) = journey.first;
        cues.add(Cue('route', span(i, n), toks[i].start, value: {'from': countries[0], 'to': countries[1]}, weight: 0.8));
      } else if (journey.isNotEmpty) {
        final (i, n) = journey.first;
        cues.add(Cue('route', span(i, n), toks[i].start, value: countries.isEmpty ? null : {'to': countries.first}, weight: 0.35));
      }
    }

    // --- lexicon cue types
    for (final type in lexicon.keys) {
      final hits = findPhrases(toks, _lex(type, lexicon));
      final seen = <int>{};
      for (final (i, n) in hits) {
        if (!seen.add(i)) continue;
        if (type == 'terrain' && placeTok.containsKey(i)) continue;
        var w = 1.0;
        if (type == 'question' || type == 'comparison' || type == 'emphasis' || type == 'stat_change' || type == 'gauge' || type == 'archive') w = 0.6;
        if (type == 'presenter' && (keys[i] == 'you' || keys[i] == 'your')) w = 0.8;
        if (type == 'object') w = 0.7;
        cues.add(Cue(type, span(i, n), toks[i].start, weight: w, value: _lexValue(type, toks, i, n)));
      }
    }
    if (line.contains('?')) cues.add(Cue('question', '?', line.indexOf('?'), weight: 0.6));

    // --- quotes / dialogue in quote marks
    final q = RegExp('["“”«»]([^"“”«»]{3,})["“”«»]').firstMatch(line);
    if (q != null) {
      final text = (q.group(1) ?? '').trim();
      if (text.split(RegExp(r'\s+')).length >= 2) {
        cues.add(Cue('dialogue', text, q.start, value: text));
        cues.add(Cue('quote', text, q.start, value: text));
      }
    }

    // --- lists: "A, B aur C" / "first… second"
    final items = listItems(line);
    if (items.length >= 3 || (items.length >= 2 && findPhrases(toks, _phrases(const ['tin', 'तीन', 'three', 'char', 'चार', 'four', 'chizen', 'चीजें', 'items', 'things', 'saman', 'सामान'])).isNotEmpty)) {
      cues.add(Cue('list', items.join(', '), 0, value: items, weight: items.length >= 3 ? 1 : 0.8));
    }

    // --- combined cues
    bool has(String t) => cues.any((c) => c.type == t);
    final numbers = cues.where((c) => c.type == 'number' || c.type == 'people_count').toList();
    if (has('people_count') && findPhrases(toks, _phrases(const ['mein se', 'में से', 'of them', 'out of', 'among them', 'inmein', 'इनमें', 'jinmein', 'जिनमें', 'unmein', 'उनमें'])).isNotEmpty) {
      cues.add(Cue('total_breakdown', numbers.first.match, numbers.first.offset, value: numbers.first.value));
    }
    if (has('survivors') && numbers.isNotEmpty) {
      final c = cues.firstWhere((x) => x.type == 'survivors');
      cues.remove(c);
      cues.add(Cue('survivors', c.match, c.offset, value: numbers.first.value));
    } else {
      cues.removeWhere((c) => c.type == 'survivors' && !key(c.match).startsWith('surviv'));
    }
    if (has('stat_change') && numbers.isEmpty) cues.removeWhere((c) => c.type == 'stat_change');
    if (has('stat_change') && numbers.isNotEmpty) {
      final c = cues.firstWhere((x) => x.type == 'stat_change');
      cues.remove(c);
      cues.add(Cue('stat_change', c.match, c.offset, value: {
        if (numbers.length >= 2) 'from': (numbers[0].value as Map)['value'],
        'to': (numbers[numbers.length >= 2 ? 1 : 0].value as Map)['value'],
        'text': (numbers.last.value as Map)['text'] ?? '',
      }));
    }
    if (has('comparison')) {
      if (numbers.length >= 2) {
        final c = cues.firstWhere((x) => x.type == 'comparison');
        cues.remove(c);
        cues.add(Cue('comparison', c.match, c.offset, value: [for (final n in numbers.take(2)) (n.value as Map)['text']]));
      } else {
        cues.removeWhere((c) => c.type == 'comparison');
      }
    }
    if (has('gauge') && numbers.isEmpty) cues.removeWhere((c) => c.type == 'gauge' && c.value == null);
    // hope next to a negation is despair: "umeed khatam", "no hope"
    for (final c in cues.where((c) => c.type == 'hope').toList()) {
      final i = toks.indexWhere((t) => t.start == c.offset);
      final near = [for (int d = 1; d <= 3; d++) if (i + d < toks.length) keys[i + d], if (i > 0) keys[i - 1]];
      if (near.any((k) => const {'khatam', 'खत्म', 'nahi', 'नहीं', 'tut', 'टूट', 'tuti', 'टूटी', 'lost', 'no', 'gone', 'kho'}.contains(k))) {
        cues.remove(c);
        cues.add(Cue('dread', c.match, c.offset));
      }
    }
    if (has('dread') && has('hope')) {
      // "zinda bache" in a death line stays survivors, not hope
      cues.removeWhere((c) => c.type == 'hope' && (has('survivors') || c.weight < 1));
    }
    // a quoted word in a "kaha" line is the quote text
    if (has('quote') && !has('dialogue')) {
      final c = cues.firstWhere((x) => x.type == 'quote');
      cues.remove(c);
      cues.add(Cue('quote', c.match, c.offset, value: _afterWord(line, c), weight: 0.8));
    }
    // a book / note "likha" line is not a quote
    if (has('book') && has('quote') && !has('dialogue')) cues.removeWhere((c) => c.type == 'quote');
    // a radio named by a character is an object; "radio par" announcements are broadcasts
    if (has('broadcast')) cues.removeWhere((c) => c.type == 'radio' && c.weight < 1);

    // times
    cues.sort((a, b) => a.offset.compareTo(b.offset));
    if (start != null) {
      final e = end ?? start + estimateDuration(line);
      final len = line.isEmpty ? 1 : line.length;
      for (final c in cues) {
        c.at = start + (e - start) * (c.offset / len);
      }
    }
    // de-duplicate (type, offset)
    final dedupe = <String>{};
    return [for (final c in cues) if (dedupe.add('${c.type}@${c.offset}')) c];
  }

  /// Seconds a line takes to say (≈ 2.6 words/s, at least 1.2 s).
  static double estimateDuration(String line) {
    final words = tokens(line).length;
    return words == 0 ? 1.2 : (words / 2.6).clamp(1.2, 30.0).toDouble();
  }

  /// Items of an enumeration "A, B aur C" (each ≤ 4 words).
  static List<String> listItems(String line) {
    final parts = line
        .split(RegExp(r'[,،;]|\s(?:aur|और|and|or|ya|या|tatha|तथा)\s', caseSensitive: false))
        .map((e) => e.trim().replaceAll(RegExp(r'[.!?।"“”]+$'), '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.length < 2) return const [];
    // keep the noun end of each part: last 1-3 words of the first part, first 1-3 words of the others
    final out = <String>[];
    for (int i = 0; i < parts.length; i++) {
      final w = parts[i].split(RegExp(r'\s+'));
      final pick = i == 0 ? w.sublist((w.length - 2).clamp(0, w.length)) : w.take(i == parts.length - 1 ? 2 : 3).toList();
      final s = pick.join(' ');
      if (s.isNotEmpty && s.length <= 28) out.add(s);
    }
    return out.length > 6 ? out.sublist(0, 6) : out;
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

  /// "12 DEC 1972" / "DEC 1972" / "1972" from the tokens around a year or month.
  static String _dateAround(List<CueToken> toks, List<String> keys, int i, int? year) {
    int? day, month, yr = year;
    for (int d = -3; d <= 3; d++) {
      final j = i + d;
      if (j < 0 || j >= toks.length) continue;
      final k = keys[j];
      if (months.containsKey(k)) month = months[k];
      final n = int.tryParse(RegExp(r'^\d+').firstMatch(k)?.group(0) ?? '');
      if (n != null && n >= 1 && n <= 31 && j != i && (d.abs() <= 2)) day ??= n;
      if (n != null && n >= 1000 && n <= 2100) yr ??= n;
    }
    const names = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    return [
      if (day != null && month != null) '$day',
      if (month != null) names[month - 1],
      if (yr != null) '$yr',
    ].join(' ');
  }

  static (String, String, String, int)? _route(List<CueToken> toks, List<String> keys, Map<int, String> placeTok, String line) {
    String nameAt(int i) {
      final p = placeTok[i];
      if (p != null) return p.startsWith('city:') ? p.split('|').last : p;
      return toks[i].raw;
    }

    // X se Y tak
    for (int i = 1; i < toks.length; i++) {
      if (keys[i] != 'se' && keys[i] != 'से') continue;
      for (int j = i + 2; j < toks.length && j <= i + 4; j++) {
        if (keys[j] != 'tak' && keys[j] != 'तक') continue;
        final a = nameAt(i - 1), b = nameAt(j - 1);
        if (placeTok.containsKey(i - 1) || placeTok.containsKey(j - 1)) {
          return (a, b, line.substring(toks[i - 1].start, toks[j].end), toks[i - 1].start);
        }
      }
    }
    // from X to Y
    for (int i = 0; i + 3 < toks.length; i++) {
      if (keys[i] != 'from') continue;
      for (int j = i + 2; j < toks.length - 1 && j <= i + 4; j++) {
        if (keys[j] != 'to') continue;
        if (placeTok.containsKey(i + 1) || placeTok.containsKey(j + 1)) {
          return (nameAt(i + 1), nameAt(j + 1), line.substring(toks[i].start, toks[j + 1].end), toks[i].start);
        }
      }
    }
    return null;
  }

  static dynamic _lexValue(String type, List<CueToken> toks, int i, int n) {
    switch (type) {
      case 'concept':
      case 'object':
      case 'organisation':
      case 'radio':
        return toks.sublist(i, i + n).map((t) => t.raw).join(' ').toUpperCase();
      case 'cta':
        final k = toks[i].key;
        for (final p in const ['whatsapp', 'telegram', 'instagram', 'facebook', 'twitter', 'youtube']) {
          if (k.startsWith(CueClassifier.key(p))) return p;
        }
        if (k == 'व्हाट्सएप') return 'whatsapp';
        return null;
    }
    return null;
  }

  static String _afterWord(String line, Cue c) {
    final rest = line.substring((c.offset + c.match.length).clamp(0, line.length)).trim();
    final s = rest.replaceFirst(RegExp(r'^(ki|कि|that|:|-)\s*', caseSensitive: false), '').trim();
    return s.isEmpty ? line.trim() : s;
  }

  /// The story tone from a whole script: "snow", "desert" or "neutral".
  static String toneOf(Iterable<String> lines) {
    var snow = 0, desert = 0;
    for (final l in lines) {
      final t = tokens(l);
      snow += findPhrases(t, _lex('snow', lexicon)).length;
      desert += findPhrases(t, _lex('desert', lexicon)).length;
    }
    if (snow >= 2 && snow >= desert) return 'snow';
    if (desert >= 2) return 'desert';
    return 'neutral';
  }
}
