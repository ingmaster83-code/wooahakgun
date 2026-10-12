require 'json'

module Jekyll
  module HakText
    module_function

    def hangul_tail?(s)
      c = s.to_s.strip.sub(/[\s\)\]\}\>'"”’.,!?~·\-]+\z/, '')[-1]
      !c.nil? && c.ord >= 0xAC00 && c.ord <= 0xD7A3
    end

    def batchim?(s)
      c = s.to_s.strip.sub(/[\s\)\]\}\>'"”’.,!?~·\-]+\z/, '')[-1]
      return false if c.nil?
      o = c.ord
      (o >= 0xAC00 && o <= 0xD7A3) ? ((o - 0xAC00) % 28 != 0) : false
    end

    def josa(word, with_b, without_b)
      return "#{word}#{with_b}(#{without_b})" unless hangul_tail?(word)
      word.to_s + (batchim?(word) ? with_b : without_b)
    end

    def i_ga(w);     josa(w, '이', '가'); end
    def eun_neun(w); josa(w, '은', '는'); end
    def eul_reul(w); josa(w, '을', '를'); end

    def fmt(n)
      n.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
    end

    def dist(m)
      m = m.to_i
      m >= 1000 ? format('%.1fkm', m / 1000.0) : "#{m}m"
    end

    def walk(m)
      [(m.to_i * 1.25 / 80).round, 1].max
    end

    # 만원 단위 -> "12억 3,500만원"
    def man(n)
      n = n.to_i
      return '-' if n <= 0
      eok = n / 10_000
      rest = n % 10_000
      if eok.positive?
        rest.zero? ? "#{eok}억원" : "#{eok}억 #{fmt(rest)}만원"
      else
        "#{fmt(n)}만원"
      end
    end

    def slug_of_trade(name, seq)
      base = name.to_s.gsub(/[^\p{Hangul}\p{Alnum}]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')[0, 22]
      "#{base}-#{seq}".gsub(/-+/, '-')
    end
  end

  class HakgunGenerator < Generator
    safe true
    priority :normal

    LV = { '초' => '초등학교', '중' => '중학교', '고' => '고등학교' }.freeze
    DO_MAP = { '서울특별시' => '서울', '부산광역시' => '부산', '대구광역시' => '대구', '인천광역시' => '인천', '광주광역시' => '광주', '대전광역시' => '대전', '울산광역시' => '울산',
               '세종특별자치시' => '세종', '경기도' => '경기', '강원특별자치도' => '강원', '강원도' => '강원', '충청북도' => '충북', '충청남도' => '충남', '전북특별자치도' => '전북',
               '전라북도' => '전북', '전라남도' => '전남', '경상북도' => '경북', '경상남도' => '경남', '제주특별자치도' => '제주', '전남광주통합특별시' => '전남' }.freeze
    CHOPUMA_M = 300
    ROWS_APT = 30

    def generate(site)
      dir = File.join(site.source, '_rawdata')
      schools = JSON.parse(File.read(File.join(dir, 'schools.json'), encoding: 'utf-8'))
      apts = []
      Dir.glob(File.join(dir, 'apts_*.json')).sort.each { |f| apts.concat(JSON.parse(File.read(f, encoding: 'utf-8'))) }
      return if schools.empty? || apts.empty?
      year = Time.now.getlocal('+09:00').year

      apt_by_idx = {}
      apts.each { |a| apt_by_idx[a['idx']] = a }

      # 단지 URL
      apts.each do |a|
        a['url'] = "/apt/#{a['slug']}/"
        a['aaptUrl'] = a['src'] == 'apt' ? "https://wooaapt.wooahouse.com/apt/#{a['slug']}/" : "https://wooaapt.wooahouse.com/trade/#{HakText.slug_of_trade(a['name'], a['seq'])}/"
      end

      # 학교 지역 정규화(시도 단축 + 단지 쪽 시군구 표기와 맞추기)
      apt_sg = Hash.new { |h, k| h[k] = true }
      dong_sg = Hash.new { |h, k| h[k] = Hash.new(0) }
      apts.each do |a|
        apt_sg["#{a['do']}|#{a['sg']}"]
        dong_sg["#{a['do']}|#{a['dong']}"][a['sg']] += 1
      end
      schools.each do |s|
        s['do'] = DO_MAP[s['sido']] || s['sido']
        sg = s['sg'].to_s
        unless apt_sg.key?("#{s['do']}|#{sg}")
          cand = dong_sg["#{s['do']}|#{s['dong']}"]
          sg = cand.max_by { |_, n| n }[0] unless cand.empty?
        end
        s['sgn'] = sg
        s['slug'] = "#{s['name'].to_s.gsub(/[^\p{Hangul}\p{Alnum}]+/, '-').gsub(/\A-|-\z/, '')[0, 24]}-#{s['id']}".gsub(/-+/, '-')
        s['url'] = "/school/#{s['slug']}/"
      end

      counts = { school: 0, apt: 0, dong: 0, sg: 0, chop: 0 }

      schools.each do |s|
        site.pages << SchoolPage.new(site, s, schools, apt_by_idx, year)
        counts[:school] += 1
      end
      apts.group_by { |a| [a['do'], a['sg'], a['dong'], a['name']] }.each_value do |g|
        next if g.size < 2
        tags = g.map { |a| a['addr'].to_s.split(' ').last(2).join(' ') }
        g.each_with_index { |a, i| a['dupTag'] = tags.count(tags[i]) > 1 || tags[i].empty? ? "#{tags[i]} #{i + 1}".strip : tags[i] }
      end
      apts.each do |a|
        site.pages << AptHakPage.new(site, a, schools, year)
        counts[:apt] += 1
      end

      # 지역 허브
      by_do_school = schools.group_by { |s| s['do'] }
      by_do_apt = apts.group_by { |a| a['do'] }
      all_do = (by_do_school.keys | by_do_apt.keys).sort
      do_rows = []
      all_do.each do |do_short|
        d_sch = by_do_school[do_short] || []
        d_apt = by_do_apt[do_short] || []
        sgs = (d_sch.map { |s| s['sgn'] } | d_apt.map { |a| a['sg'] }).compact.reject(&:empty?)
        sg_rows = sgs.map do |sg|
          ss = d_sch.select { |s| s['sgn'] == sg }
          aa = d_apt.select { |a| a['sg'] == sg }
          chop = aa.count { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= CHOPUMA_M }
          { 'name' => sg, 'schools' => ss.size, 'apts' => aa.size, 'chop' => chop }
        end.sort_by { |h| [-h['schools'], h['name']] }
        do_rows << { 'name' => do_short, 'schools' => d_sch.size, 'apts' => d_apt.size, 'chop' => sg_rows.sum { |h| h['chop'] } }
        site.pages << DoHubPage.new(site, do_short, sg_rows, d_sch.size, d_apt.size)

        sg_rows.each do |row|
          sg = row['name']
          ss = d_sch.select { |s| s['sgn'] == sg }
          aa = d_apt.select { |a| a['sg'] == sg }
          dongs = (ss.map { |s| s['dong'] } | aa.map { |a| a['dong'] }).compact.reject(&:empty?)
          dong_rows = dongs.map do |dg|
            ds = ss.select { |s| s['dong'] == dg }
            da = aa.select { |a| a['dong'] == dg }
            { 'name' => dg, 'schools' => ds.size, 'apts' => da.size, 'ds' => ds, 'da' => da }
          end.select { |h| h['schools'] + h['apts'] >= 2 }
          site.pages << SgHubPage.new(site, do_short, sg, ss, aa, dong_rows, schools, year)
          counts[:sg] += 1
          dong_rows.each do |h|
            site.pages << DongHubPage.new(site, do_short, sg, h['name'], h['ds'], h['da'], dong_rows, schools)
            counts[:dong] += 1
          end
          # 초품아 시군구 페이지
          chop_list = aa.select { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= CHOPUMA_M }
          unless chop_list.size < 3
            site.pages << ChopumaPage.new(site, do_short, sg, chop_list, schools)
            counts[:chop] += 1
          end
        end
        chop_do = d_apt.select { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= CHOPUMA_M }
        site.pages << ChopumaPage.new(site, do_short, nil, chop_do, schools) unless chop_do.empty?
      end
      chop_all = apts.select { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= CHOPUMA_M }
      site.pages << ChopumaPage.new(site, nil, nil, chop_all, schools)

      site.data['hak_stats'] = {
        'schools' => HakText.fmt(schools.size), 'apts' => HakText.fmt(apts.size), 'chop' => HakText.fmt(chop_all.size),
        'elem' => HakText.fmt(schools.count { |s| s['lv'] == '초' }), 'mid' => HakText.fmt(schools.count { |s| s['lv'] == '중' }), 'high' => HakText.fmt(schools.count { |s| s['lv'] == '고' }),
        'do_rows' => do_rows.map { |h| h.merge('schools' => HakText.fmt(h['schools']), 'apts' => HakText.fmt(h['apts']), 'chop' => HakText.fmt(h['chop'])) },
        'top_chop' => chop_all.sort_by { |a| [-(a['ho'].to_i), a['name']] }.first(12).map { |a| ChopumaPage.row(a, schools) }
      }

      # 홈 검색 색인(학교 + 단지)
      idx = schools.map { |s| { 'n' => s['name'], 't' => LV[s['lv']], 'l' => "#{s['do']} #{s['sgn']}", 'u' => s['url'] } }
      idx.concat(apts.map { |a| { 'n' => a['name'], 't' => '아파트', 'l' => "#{a['do']} #{a['sg']} #{a['dong']}", 'u' => a['url'] } })
      pg = PageWithoutAFile.new(site, site.source, '', 'search_index.json')
      pg.content = JSON.generate(idx)
      pg.data['layout'] = nil
      pg.data['sitemap'] = false
      site.pages << pg
      Jekyll.logger.info 'HakgunGenerator:', "학교 #{counts[:school]} / 단지 #{counts[:apt]} / 동 #{counts[:dong]} / 시군구 #{counts[:sg]} / 초품아 #{counts[:chop]}"
    end
  end

  class HakBasePage < Page
    def setup(site, dir, layout)
      @site = site
      @base = site.source
      @dir = dir
      @name = 'index.html'
      process(@name)
      read_yaml(File.join(@base, '_layouts'), "#{layout}.html")
      data['layout'] = layout
    end

    def seo(title, desc)
      data['title'] = title
      data['description'] = desc[0, 155]
    end

    def faq(pairs)
      data['faq'] = pairs.map { |q, a| { 'q' => q, 'a' => a } }
    end

    def f(n)
      HakText.fmt(n)
    end
  end

  # ── 학교 페이지 ─────────────────────────────────────
  class SchoolPage < HakBasePage
    def initialize(site, s, schools, apt_by_idx, year)
      setup(site, "school/#{s['slug']}", 'school')
      lvn = HakgunGenerator::LV[s['lv']]
      name = s['name']
      rows = s['apts'].map do |ai, d|
        a = apt_by_idx[ai]
        next nil unless a
        { 'name' => a['name'], 'url' => a['url'], 'aaptUrl' => a['aaptUrl'], 'dist' => HakText.dist(d), 'distN' => d, 'walk' => HakText.walk(d), 'ho' => a['ho'].to_i, 'by' => a['by'].to_i,
          'rep' => a['rep'] ? "전용 #{a['rep']['a']}㎡(약 #{a['rep']['py']}평형) 평균 #{HakText.man(a['rep']['avg'])}" : '-', 'loc' => "#{a['sg']} #{a['dong']}" }
      end.compact
      near = s['near'].map { |si, d| t = schools[si]; { 'name' => t['name'], 'url' => t['url'], 'dist' => HakText.dist(d), 'type' => t['type'] } }
      same = schools.select { |t| t['do'] == s['do'] && t['sgn'] == s['sgn'] && t['dong'] == s['dong'] && t['id'] != s['id'] && !s['dong'].to_s.empty? }.sort_by { |t| [t['lv'] == s['lv'] ? 0 : 1, t['name']] }.first(10)
                      .map { |t| { 'name' => t['name'], 'url' => t['url'], 'level' => HakgunGenerator::LV[t['lv']] } }
      data['schoolName'] = name
      data['level'] = lvn
      data['type'] = s['type']
      data['founded'] = s['founded']
      data['road'] = s['road']
      data['jibun'] = s['jibun']
      data['office'] = s['office']
      data['sidoOffice'] = s['sidoOffice']
      data['doShort'] = s['do']
      data['sigungu'] = s['sgn']
      data['dong'] = s['dong']
      data['rows'] = rows
      data['n500'] = s['n500']
      data['n1k'] = s['n1k']
      data['nearSchools'] = near
      data['sameDong'] = same
      sum = +"#{name}#{HakText.eun_neun(name).sub(name, '')}"
      sum = +"#{HakText.eun_neun(name)} #{s['do']} #{s['sgn']} #{s['dong']}에 있는 #{s['type']} #{lvn}입니다."
      sum << " #{s['founded'][0, 4]}년에 설립됐고 #{s['office']} 관할입니다." unless s['founded'].to_s.empty?
      if s['n1k'].positive?
        nearest = rows.first
        sum << " 학교에서 직선 500m 안에 아파트 단지 #{s['n500']}곳, 1km 안에 #{s['n1k']}곳이 있습니다."
        sum << " 가장 가까운 단지는 #{nearest['name']}(#{nearest['dist']}, 도보 약 #{nearest['walk']}분)입니다." if nearest
      else
        sum << ' 직선 1km 안에 확인된 아파트 단지는 없습니다.'
      end
      data['summary'] = sum
      ttl = s['n1k'].positive? ? "#{name} 주변 아파트 #{s['n1k']}곳 - 학군·초품아 단지와 시세" : "#{name} 위치·주변 학교 정보"
      seo("#{ttl} | #{s['do']} #{s['sgn']}", "#{s['do']} #{s['sgn']} #{s['dong']} #{name}(#{lvn}) 위치와 주변 아파트 단지(1km 이내 #{s['n1k']}곳)의 거리·도보 시간, 실거래가를 확인하세요.")
      pairs = []
      pairs << ["#{name} 근처에는 아파트가 몇 곳 있나요?", s['n1k'].positive? ? "직선거리 기준 500m 안에 #{s['n500']}곳, 1km 안에 #{s['n1k']}곳의 아파트 단지가 있습니다. 거리가 가까운 순서로 아래 표에 정리했습니다." : '직선 1km 안에 확인된 아파트 단지는 없습니다.']
      pairs << ["#{name}에 배정되는 아파트는 어디인가요?", '이 사이트의 거리는 직선거리 기준 참고 정보입니다. 실제 학교 배정(통학구역)은 교육지원청이 고시하며, 거리가 가까워도 배정 학교가 다를 수 있으니 입주·계약 전에 관할 교육지원청에서 확인하세요.']
      pairs << ["#{name}의 주소는 어디인가요?", "도로명주소는 #{s['road']}, 지번주소는 #{s['jibun']}입니다."]
      faq(pairs)
    end
  end

  # ── 단지(학군) 페이지 ───────────────────────────────
  class AptHakPage < HakBasePage
    def initialize(site, a, schools, year)
      setup(site, "apt/#{a['slug']}", 'apt')
      name = a['name']
      ns = a['ns']
      groups = %w[초 중 고].map do |lv|
        items = (ns[lv] || []).map do |si, d|
          t = schools[si]
          { 'name' => t['name'], 'url' => t['url'], 'type' => t['type'], 'dist' => HakText.dist(d), 'distN' => d, 'walk' => HakText.walk(d), 'office' => t['office'] }
        end
        { 'level' => HakgunGenerator::LV[lv], 'lv' => lv, 'items' => items, 'n500' => ns["#{lv}_n500"].to_i, 'n1k' => ns["#{lv}_n1k"].to_i }
      end
      elem = groups[0]['items'].first
      chop = elem && elem['distN'] <= HakgunGenerator::CHOPUMA_M
      data['aptName'] = name
      data['doShort'] = a['do']
      data['sigungu'] = a['sg']
      data['dong'] = a['dong']
      data['addr'] = a['addr']
      data['ho'] = a['ho'].to_i
      data['by'] = a['by'].to_i
      data['groups'] = groups
      data['chopuma'] = chop
      data['aaptUrl'] = a['aaptUrl']
      data['rep'] = a['rep'] ? "전용 #{a['rep']['a']}㎡(약 #{a['rep']['py']}평형) 최근 12개월 평균 #{HakText.man(a['rep']['avg'])}" : nil
      s = +"#{HakText.eun_neun(name)} #{a['do']} #{a['sg']} #{a['dong']}에 있는 아파트"
      s << "(#{a['by']}년 준공#{a['ho'].to_i.positive? ? ", #{f(a['ho'])}세대" : ''})" if a['by'].to_i.positive?
      s << '입니다. '
      if elem
        s << "가장 가까운 초등학교는 #{elem['name']}(#{elem['type']})으로 직선거리 #{elem['dist']}, 도보 약 #{elem['walk']}분입니다. "
        s << (chop ? "직선 #{HakgunGenerator::CHOPUMA_M}m 이내라 초등학교를 끼고 있는 이른바 '초품아' 단지에 해당합니다. " : "직선 #{HakgunGenerator::CHOPUMA_M}m 이내 초등학교는 없어 '초품아'로 보기는 어렵습니다. ")
      else
        s << '직선 3km 안에서 확인된 초등학교가 없습니다. '
      end
      mid = groups[1]['items'].first
      high = groups[2]['items'].first
      s << "중학교는 #{mid['name']}(#{mid['dist']}), " if mid
      s << "고등학교는 #{high['name']}(#{high['dist']})이 가장 가깝습니다." if high
      s << " 반경 1km 안에 초등학교 #{groups[0]['n1k']}곳, 중학교 #{groups[1]['n1k']}곳, 고등학교 #{groups[2]['n1k']}곳이 있습니다."
      data['summary'] = s
      seo("#{name}#{a['dupTag'] ? "(#{a['dupTag']})" : ''} 학군 - 초품아 여부·주변 초중고 거리 | #{a['do']} #{a['sg']} #{a['dong']}", "#{a['do']} #{a['sg']} #{a['dong']} #{name}의 학군 정보. #{elem ? "가장 가까운 초등학교 #{elem['name']} #{elem['dist']}(도보 약 #{elem['walk']}분)" : ''} 초중고 거리와 초품아 여부, 실거래가 링크.")
      pairs = []
      pairs << ["#{name}은(는) 초품아인가요?", elem ? (chop ? "가장 가까운 초등학교 #{elem['name']}까지 직선거리 #{elem['dist']}로, #{HakgunGenerator::CHOPUMA_M}m 이내여서 초품아에 해당합니다." : "가장 가까운 초등학교 #{elem['name']}까지 직선거리 #{elem['dist']}로, #{HakgunGenerator::CHOPUMA_M}m 이내가 아니어서 초품아로 보기는 어렵습니다.") : '직선 3km 안에 확인된 초등학교가 없습니다.']
      pairs << ["#{name} 배정 초등학교는 어디인가요?", '실제 배정은 교육지원청이 고시한 통학구역에 따라 정해지며 직선거리와 다를 수 있습니다. 이 페이지는 가까운 학교를 직선거리로 보여주는 참고 정보이니, 입주·계약 전 관할 교육지원청에서 확인하세요.']
      pairs << ["#{name} 실거래가는 어디서 볼 수 있나요?", '우아아파트에서 평형별 매매·전월세 실거래가와 신고가를 확인할 수 있습니다. 이 페이지 아래의 링크를 이용하세요.']
      faq(pairs)
    end
  end

  # ── 지역 허브 ───────────────────────────────────────
  class DoHubPage < HakBasePage
    def initialize(site, do_short, sg_rows, n_sch, n_apt)
      setup(site, "region/#{do_short}", 'do')
      data['doShort'] = do_short
      data['sgRows'] = sg_rows.map { |h| h.merge('schools' => f(h['schools']), 'apts' => f(h['apts']), 'chop' => f(h['chop'])) }
      data['nSchools'] = f(n_sch)
      data['nApts'] = f(n_apt)
      data['summary'] = "#{do_short}에는 초·중·고등학교 #{f(n_sch)}곳과 학군 정보를 제공하는 아파트 단지 #{f(n_apt)}곳이 있습니다. 시군구를 선택해 학교와 주변 아파트를 확인하세요."
      seo("#{do_short} 학군·초품아 아파트 - 학교 #{f(n_sch)}곳, 단지 #{f(n_apt)}곳", "#{do_short} 초중고등학교 #{f(n_sch)}곳과 아파트 #{f(n_apt)}개 단지의 학군 정보를 시군구별로 확인하세요. 초품아 단지, 학교 주변 아파트 시세.")
    end
  end

  class SgHubPage < HakBasePage
    def initialize(site, do_short, sg, ss, aa, dong_rows, schools, year)
      setup(site, "region/#{do_short}/#{sg}", 'sigungu')
      chop = aa.select { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= HakgunGenerator::CHOPUMA_M }
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['nSchools'] = ss.size
      data['nApts'] = aa.size
      data['nChop'] = chop.size
      data['dongRows'] = dong_rows.sort_by { |h| [-(h['schools'] + h['apts']), h['name']] }.map { |h| { 'name' => h['name'], 'schools' => h['schools'], 'apts' => h['apts'] } }
      by_lv = %w[초 중 고].map { |lv| { 'level' => HakgunGenerator::LV[lv], 'n' => ss.count { |s| s['lv'] == lv } } }
      data['byLevel'] = by_lv
      data['chopRows'] = chop.sort_by { |a| [-(a['ho'].to_i), a['name']] }.first(12).map { |a| ChopumaPage.row(a, schools) }
      data['summary'] = "#{do_short} #{sg}에는 초등학교 #{by_lv[0]['n']}곳, 중학교 #{by_lv[1]['n']}곳, 고등학교 #{by_lv[2]['n']}곳이 있고, 학군 정보를 제공하는 아파트 단지는 #{aa.size}곳입니다. 이 중 초등학교가 직선 #{HakgunGenerator::CHOPUMA_M}m 이내에 있는 '초품아' 단지는 #{chop.size}곳입니다."
      seo("#{do_short} #{sg} 학군·초품아 아파트 - 학교 #{ss.size}곳, 단지 #{aa.size}곳", "#{do_short} #{sg} 초중고 #{ss.size}곳과 아파트 #{aa.size}개 단지의 학군 정보. 초품아 단지 #{chop.size}곳, 동네별 학교와 주변 아파트를 확인하세요.")
    end
  end

  class DongHubPage < HakBasePage
    def initialize(site, do_short, sg, dong, ds, da, dong_rows, schools)
      setup(site, "region/#{do_short}/#{sg}/#{dong}", 'dong')
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['dong'] = dong
      data['schoolRows'] = ds.sort_by { |s| [%w[초 중 고].index(s['lv']).to_i, s['name']] }.map { |s| { 'name' => s['name'], 'url' => s['url'], 'level' => HakgunGenerator::LV[s['lv']], 'type' => s['type'], 'n500' => s['n500'], 'n1k' => s['n1k'] } }
      data['aptRows'] = da.sort_by { |a| [(a['ns']['초'] || []).first ? a['ns']['초'].first[1] : 99_999, a['name']] }.first(60).map do |a|
        e = (a['ns']['초'] || []).first
        { 'name' => a['name'], 'url' => a['url'], 'elem' => e ? schools[e[0]]['name'] : '-', 'dist' => e ? HakText.dist(e[1]) : '-', 'chop' => e && e[1] <= HakgunGenerator::CHOPUMA_M, 'by' => a['by'].to_i, 'ho' => a['ho'].to_i }
      end
      data['nSchools'] = ds.size
      data['nApts'] = da.size
      data['neighbors'] = dong_rows.reject { |h| h['name'] == dong }.sort_by { |h| [-(h['schools'] + h['apts']), h['name']] }.first(12).map { |h| { 'name' => h['name'] } }
      chop = da.count { |a| (a['ns']['초'] || []).first && a['ns']['초'].first[1] <= HakgunGenerator::CHOPUMA_M }
      data['summary'] = "#{do_short} #{sg} #{dong}에는 초·중·고등학교 #{ds.size}곳과 아파트 단지 #{da.size}곳이 있습니다. 초등학교가 직선 #{HakgunGenerator::CHOPUMA_M}m 이내에 있는 '초품아' 단지는 #{chop}곳입니다."
      seo("#{sg} #{dong} 학군·초품아 아파트 - 학교 #{ds.size}곳, 단지 #{da.size}곳", "#{do_short} #{sg} #{dong}의 초중고 학교와 아파트 단지 학군 정보. 초품아 단지 #{chop}곳, 단지별 가장 가까운 초등학교와 거리를 확인하세요.")
    end
  end

  class ChopumaPage < HakBasePage
    def self.row(a, schools)
      e = (a['ns']['초'] || []).first
      { 'name' => a['name'], 'url' => a['url'], 'loc' => "#{a['do']} #{a['sg']} #{a['dong']}", 'elem' => e ? schools[e[0]]['name'] : '-', 'dist' => e ? HakText.dist(e[1]) : '-',
        'walk' => e ? HakText.walk(e[1]) : 0, 'ho' => a['ho'].to_i, 'by' => a['by'].to_i,
        'rep' => a['rep'] ? "전용 #{a['rep']['a']}㎡ 평균 #{HakText.man(a['rep']['avg'])}" : '-' }
    end

    def initialize(site, do_short, sg, list, schools)
      if sg
        setup(site, "chopuma/#{do_short}/#{sg}", 'chopuma')
        scope = "#{do_short} #{sg}"
      elsif do_short
        setup(site, "chopuma/#{do_short}", 'chopuma')
        scope = do_short
      else
        setup(site, 'chopuma', 'chopuma')
        scope = '전국'
      end
      sorted = list.sort_by { |a| [-(a['ho'].to_i), a['name']] }
      data['scope'] = scope
      data['doShort'] = do_short
      data['sigungu'] = sg
      data['count'] = list.size
      data['rows'] = sorted.first(sg ? 100 : 80).map { |a| ChopumaPage.row(a, schools) }
      data['summary'] = "#{scope}에서 초등학교가 직선 #{HakgunGenerator::CHOPUMA_M}m 이내에 있는 '초품아' 아파트 단지는 #{f(list.size)}곳입니다. 세대수가 많은 순서로 정리했으며, 거리는 단지와 학교 사이 직선거리입니다. 실제 통학 경로와 학교 배정은 다를 수 있습니다."
      seo("#{scope} 초품아 아파트 #{f(list.size)}곳 - 초등학교 300m 이내 단지", "#{scope} 초품아(초등학교 직선 300m 이내) 아파트 #{f(list.size)}곳. 단지별 가장 가까운 초등학교와 거리, 도보 시간, 실거래가 링크.")
    end
  end

  # 사이트맵: 5만 건 한도 때문에 40,000건씩 분할 + 인덱스
  class HakSitemapGenerator < Generator
    safe true
    priority :lowest
    CHUNK = 40_000

    def generate(site)
      urls = site.pages.reject { |p| p.url.to_s.end_with?('.json', '.xml', '.txt', '.js', '.css') || p.url.to_s == '/404.html' || p.data['sitemap'] == false }.map { |p| p.url }.uniq
      base = site.config['url'].to_s
      chunks = urls.each_slice(CHUNK).to_a
      chunks.each_with_index do |c, idx|
        body = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
        c.each { |u| body << "  <url><loc>#{base}#{u}</loc></url>\n" }
        body << "</urlset>\n"
        site.pages << raw_page(site, "sitemap-#{idx + 1}.xml", body)
      end
      index = +"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<sitemapindex xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
      chunks.each_index { |idx| index << "  <sitemap><loc>#{base}/sitemap-#{idx + 1}.xml</loc></sitemap>\n" }
      index << "</sitemapindex>\n"
      site.pages << raw_page(site, 'sitemap.xml', index)
      Jekyll.logger.info 'HakSitemap:', "#{urls.size}개 URL → #{chunks.size}개 사이트맵"
    end

    private

    def raw_page(site, name, content)
      pg = PageWithoutAFile.new(site, site.source, '', name)
      pg.content = content
      pg.data['layout'] = nil
      pg.data['sitemap'] = false
      pg
    end
  end
end
