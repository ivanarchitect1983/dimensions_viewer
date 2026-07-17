require File.expand_path('rays', __dir__)
require File.expand_path('intersections', __dir__)
require File.expand_path('hide_others', __dir__)

module DimViewer
  module Main

    VERSION = 23

    GITHUB_URL = 'https://github.com/ivanarchitect1983/dimensions_viewer'

    @dialog = nil
    @sel_observer = nil

    def self.pt_xyz(point3d)
      a = point3d.to_a
      [a[0].to_f, a[1].to_f, a[2].to_f]
    end

    def self.collect_points(entity, transform, pts)
      return unless entity && entity.valid?

      case entity
      when Sketchup::Group
        t = transform * entity.transformation
        entity.entities.each { |e| collect_points(e, t, pts) }
      when Sketchup::ComponentInstance
        t = transform * entity.transformation
        entity.definition.entities.each { |e| collect_points(e, t, pts) }
      when Sketchup::Edge
        entity.vertices.each do |v|
          pts << pt_xyz(v.position.transform(transform))
        end
      when Sketchup::Face
        entity.vertices.each do |v|
          pts << pt_xyz(v.position.transform(transform))
        end
      when Sketchup::Vertex
        pts << pt_xyz(entity.position.transform(transform))
      when Sketchup::CLine
        pts << pt_xyz(entity.start.transform(transform)) if entity.start
        pts << pt_xyz(entity.end.transform(transform)) if entity.end
      end
    rescue => e
      puts "DimViewer collect_points error: #{e.message}"
    end

    def self.bounds_of(pts)
      return nil if pts.empty?

      min = pts[0].dup
      max = pts[0].dup

      pts.each do |p|
        3.times do |i|
          min[i] = p[i] if p[i] < min[i]
          max[i] = p[i] if p[i] > max[i]
        end
      end

      [min, max]
    end

    def self.world_bounds(entity, base_transform)
      pts = []
      collect_points(entity, base_transform, pts)
      bounds_of(pts)
    end

    def self.local_bounds(entity)
      return nil unless entity.is_a?(Sketchup::Group) ||
                        entity.is_a?(Sketchup::ComponentInstance)

      pts = []
      ents = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      ents.each { |e| collect_points(e, Geom::Transformation.new, pts) }

      b = bounds_of(pts)
      return nil unless b

      min, max = b
      [max[0] - min[0], max[1] - min[1], max[2] - min[2]]
    rescue => e
      puts "DimViewer local_bounds error: #{e.message}"
      nil
    end

    def self.local_box(entity)
      return nil unless entity.is_a?(Sketchup::Group) ||
                        entity.is_a?(Sketchup::ComponentInstance)

      pts = []
      ents = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      ents.each { |e| collect_points(e, Geom::Transformation.new, pts) }

      bounds_of(pts)
    rescue => e
      puts "DimViewer local_box error: #{e.message}"
      nil
    end

    def self.rotated?(entity)
      return false unless entity.is_a?(Sketchup::Group) ||
                          entity.is_a?(Sketchup::ComponentInstance)

      t = entity.transformation

      xa = t.xaxis.normalize
      ya = t.yaxis.normalize
      za = t.zaxis.normalize

      tol = 0.9999

      (xa % X_AXIS).abs < tol ||
        (ya % Y_AXIS).abs < tol ||
        (za % Z_AXIS).abs < tol
    rescue => e
      puts "DimViewer rotated? error: #{e.message}"
      false
    end

    def self.parse_arithmetic(str)
      s = str.to_s.strip.tr(',', '.')
      return nil if s.empty?
      return nil unless s =~ /\A[\d\s\.\+\-\*\/$\)]+\z/

      tokens = s.scan(/\d+\.?\d*|[\+\-\*\/\($]/)
      return nil if tokens.empty?

      pos = 0
      read_expr = nil
      read_term = nil
      read_factor = nil

      read_factor = lambda do
        t = tokens[pos]

        if t == '('
          pos += 1
          v = read_expr.call
          pos += 1 if tokens[pos] == ')'
          v
        elsif t == '-'
          pos += 1
          -read_factor.call
        elsif t == '+'
          pos += 1
          read_factor.call
        else
          pos += 1
          t.to_f
        end
      end

      read_term = lambda do
        v = read_factor.call

        while tokens[pos] == '*' || tokens[pos] == '/'
          op = tokens[pos]
          pos += 1

          r = read_factor.call

          v =
            if op == '*'
              v * r
            else
              r.abs < 1e-12 ? v : v / r
            end
        end

        v
      end

      read_expr = lambda do
        v = read_term.call

        while tokens[pos] == '+' || tokens[pos] == '-'
          op = tokens[pos]
          pos += 1

          r = read_term.call
          v = op == '+' ? v + r : v - r
        end

        v
      end

      result = read_expr.call
      result.is_a?(Numeric) && result.finite? ? result : nil
    rescue
      nil
    end

    def self.apply_scale(axis_key, target_mm)
      model = Sketchup.active_model
      sel = model.selection

      return unless sel.length == 1

      entity = sel.first

      return unless entity.is_a?(Sketchup::Group) ||
                    entity.is_a?(Sketchup::ComponentInstance)

      return if target_mm.nil? || target_mm <= 0

      box = local_box(entity)
      return unless box

      min, max = box

      axis_i = {
        'x' => 0,
        'y' => 1,
        'z' => 2
      }[axis_key]

      return unless axis_i

      t = entity.transformation
      axis_vec = [t.xaxis, t.yaxis, t.zaxis][axis_i].normalize

      corners = [
        [min[0], min[1], min[2]],
        [max[0], min[1], min[2]],
        [min[0], max[1], min[2]],
        [max[0], max[1], min[2]],
        [min[0], min[1], max[2]],
        [max[0], min[1], max[2]],
        [min[0], max[1], max[2]],
        [max[0], max[1], max[2]]
      ].map { |c| Geom::Point3d.new(*c).transform(t) }

      projs = corners.map do |p|
        p.x * axis_vec.x + p.y * axis_vec.y + p.z * axis_vec.z
      end

      current_in = projs.max - projs.min
      return if current_in < 1e-9

      target_in = target_mm / 25.4
      factor = target_in / current_in

      return if (factor - 1.0).abs < 1e-6

      sx = axis_i == 0 ? factor : 1.0
      sy = axis_i == 1 ? factor : 1.0
      sz = axis_i == 2 ? factor : 1.0

      scale_t = Geom::Transformation.scaling(ORIGIN, sx, sy, sz)

      model.start_operation('Задать размер по оси', true)
      entity.transformation = entity.transformation * scale_t
      model.commit_operation

      update
    rescue => e
      puts "DimViewer apply_scale error: #{e.message}"

      begin
        model.abort_operation
      rescue
      end
    end

    def self.calc_volume_area(entity, transform)
      volume = 0.0
      area = 0.0

      return [0.0, 0.0] unless entity && entity.valid?

      case entity
      when Sketchup::Group
        t = transform * entity.transformation

        entity.entities.each do |e|
          v, a = calc_volume_area(e, t)
          volume += v
          area += a
        end
      when Sketchup::ComponentInstance
        t = transform * entity.transformation

        entity.definition.entities.each do |e|
          v, a = calc_volume_area(e, t)
          volume += v
          area += a
        end
      when Sketchup::Face
        mesh = entity.mesh(0)
        pts = mesh.points.map { |p| pt_xyz(p.transform(transform)) }

        mesh.polygons.each do |poly|
          p1 = pts[poly[0].abs - 1]
          p2 = pts[poly[1].abs - 1]
          p3 = pts[poly[2].abs - 1]

          ax, ay, az = p1
          bx, by, bz = p2
          cx, cy, cz = p3

          ux = bx - ax
          uy = by - ay
          uz = bz - az

          vx = cx - ax
          vy = cy - ay
          vz = cz - az

          crx = uy * vz - uz * vy
          cry = uz * vx - ux * vz
          crz = ux * vy - uy * vx

          area += Math.sqrt(crx * crx + cry * cry + crz * crz) / 2.0

          cx2 = by * cz - bz * cy
          cy2 = bz * cx - bx * cz
          cz2 = bx * cy - by * cx

          volume += (ax * cx2 + ay * cy2 + az * cz2) / 6.0
        end
      end

      [volume, area]
    rescue => e
      puts "DimViewer calc_volume_area error: #{e.message}"
      [volume, area]
    end

    def self.calc_perimeter(entity, transform)
      return 0.0 unless entity && entity.valid?

      length = 0.0

      case entity
      when Sketchup::Edge
        a = pt_xyz(entity.start.position.transform(transform))
        b = pt_xyz(entity.end.position.transform(transform))

        dx = b[0] - a[0]
        dy = b[1] - a[1]
        dz = b[2] - a[2]

        length += Math.sqrt(dx * dx + dy * dy + dz * dz)
      when Sketchup::Group
        t = transform * entity.transformation
        entity.entities.each { |e| length += calc_perimeter(e, t) }
      when Sketchup::ComponentInstance
        t = transform * entity.transformation
        entity.definition.entities.each { |e| length += calc_perimeter(e, t) }
      end

      length
    rescue => e
      puts "DimViewer calc_perimeter error: #{e.message}"
      length
    end

    def self.describe_selection(sel, count)
      if count == 1
        e = sel.first

        if e.is_a?(Sketchup::Group)
          n = e.name.to_s.strip
          n.empty? ? 'Группа' : "Группа: #{n}"
        elsif e.is_a?(Sketchup::ComponentInstance)
          n = e.name.to_s.strip
          dn = e.definition.name.to_s.strip

          if !n.empty?
            "Компонент: #{n}"
          elsif !dn.empty?
            "Компонент: #{dn}"
          else
            'Компонент'
          end
        elsif e.is_a?(Sketchup::Face)
          'Грань'
        elsif e.is_a?(Sketchup::Edge)
          'Ребро'
        else
          e.class.name.split('::').last
        end
      else
        "Выбрано объектов: #{count}"
      end
    end

    def self.send_empty
      return unless @dialog && @dialog.visible?

      @dialog.execute_script('showEmpty();') rescue nil
    end

    def self.jstr(s)
      s.to_s
       .gsub('\\', '\\\\')
       .gsub("'", "\\\\'")
       .gsub("\r", ' ')
       .gsub("\n", ' ')
    end

    def self.js_object(hash)
      hash.map do |k, v|
        val =
          case v
          when nil
            'null'
          when true
            'true'
          when false
            'false'
          when Numeric
            v.to_s
          else
            "'#{jstr(v)}'"
          end

        "'#{k}':#{val}"
      end.join(',')
    end

    def self.update
      return unless @dialog && @dialog.visible?

      begin
        model = Sketchup.active_model
        return unless model

        sel = model.selection
        edit_t = Geom::Transformation.new

        if sel.empty?
          send_empty
          refresh_preview
          return
        end

        gmin = nil
        gmax = nil

        total_volume = 0.0
        total_area = 0.0
        total_perim = 0.0

        sel.each do |e|
          next unless e && e.valid?

          wb = world_bounds(e, edit_t)

          if wb
            emin, emax = wb

            if gmin.nil?
              gmin = emin.dup
              gmax = emax.dup
            else
              3.times do |i|
                gmin[i] = emin[i] if emin[i] < gmin[i]
                gmax[i] = emax[i] if emax[i] > gmax[i]
              end
            end
          end

          v, a = calc_volume_area(e, edit_t)
          total_volume += v
          total_area += a
          total_perim += calc_perimeter(e, edit_t)
        end

        if gmin.nil?
          send_empty
          refresh_preview
          return
        end

        dx = gmax[0] - gmin[0]
        dy = gmax[1] - gmin[1]
        dz = gmax[2] - gmin[2]

        count = sel.length
        info = describe_selection(sel, count)

        lx = nil
        ly = nil
        lz = nil

        if count == 1 && rotated?(sel.first)
          lb = local_bounds(sel.first)
          lx, ly, lz = lb if lb
        end

        scalable = count == 1 &&
                   (sel.first.is_a?(Sketchup::Group) ||
                    sel.first.is_a?(Sketchup::ComponentInstance))

        gaps = nil
        gaps = DimViewer::Rays.compute_gaps(sel.first) if scalable

        pair = nil

        if count == 2
          a = sel[0]
          b = sel[1]

          ok = [a, b].all? do |e|
            e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          end

          pair = DimViewer::Rays.pair_gaps(a, b) if ok
        end

        dx_mm = dx * 25.4
        dy_mm = dy * 25.4
        dz_mm = dz * 25.4

        vol_mm3 = total_volume.abs * (25.4**3)
        area_mm2 = total_area * (25.4**2)
        perim_mm = total_perim * 25.4

        data = {
          'info' => info,
          'count' => count,
          'dx' => dx_mm.round(2),
          'dy' => dy_mm.round(2),
          'dz' => dz_mm.round(2),
          'lx' => lx.nil? ? nil : (lx * 25.4).round(2),
          'ly' => ly.nil? ? nil : (ly * 25.4).round(2),
          'lz' => lz.nil? ? nil : (lz * 25.4).round(2),
          'volume' => vol_mm3.round(2),
          'area' => area_mm2.round(2),
          'perim' => perim_mm.round(2),
          'scalable' => scalable
        }

        gap_js = 'null'

        if gaps
          parts = []

          gaps.each do |k, v|
            parts << "'#{k}':#{v.nil? ? 'null' : v.round(1)}"
          end

          gap_js = "{#{parts.join(',')}}"
        end

        pair_js = 'null'

        if pair
          pparts = []

          pair.each do |k, v|
            next if v.nil?

            pparts << "'#{k}':#{v.round(1)}"
          end

          pair_js = "{#{pparts.join(',')}}" unless pparts.empty?
        end

        script = "showData({#{js_object(data)}}, #{gap_js}, #{pair_js});"

        @dialog.execute_script(script)
        refresh_preview
      rescue => e
        puts "DimViewer update error: #{e.message}"
        puts e.backtrace.join("\n") if e.backtrace
      end
    end

    def self.preview_active?
      DimViewer::Rays.preview_active?
    end

    def self.toggle_preview
      DimViewer::Rays.toggle_preview
    end

    def self.notify_preview_state
      return unless @dialog

      state = preview_active? ? 'true' : 'false'
      @dialog.execute_script("setPreviewState(#{state});") rescue nil
    end

    def self.refresh_preview
      DimViewer::Rays.refresh_preview
    end

    def self.notify_walls_state
      return unless @dialog

      @dialog.execute_script("setWallsState(#{DimViewer::Rays.walls_count});") rescue nil
    end

    def self.entity_display_name(entity)
      return 'Объект' unless entity && entity.valid?

      if entity.is_a?(Sketchup::Group)
        name = entity.name.to_s.strip
        name.empty? ? 'Группа' : "Группа: #{name}"
      elsif entity.is_a?(Sketchup::ComponentInstance)
        name = entity.name.to_s.strip
        def_name = entity.definition.name.to_s.strip

        if !name.empty?
          "Компонент: #{name}"
        elsif !def_name.empty?
          "Компонент: #{def_name}"
        else
          'Компонент'
        end
      else
        entity.class.name.split('::').last
      end
    rescue
      'Объект'
    end

    def self.intersections_report_js(items)
      items ||= []

      rows = items.map do |item|
        first = item[:first] || item['first']
        second = item[:second] || item['second']
        volume = item[:volume] || item['volume']

        mode =
          if volume && volume.valid?
            'Создан красный объём пересечения и overlay-контур'
          else
            'Пересечение найдено'
          end

        "{'a':'#{jstr(entity_display_name(first))}','b':'#{jstr(entity_display_name(second))}','mode':'#{jstr(mode)}'}"
      end

      "[#{rows.join(',')}]"
    rescue => e
      puts "DimViewer intersections_report_js error: #{e.message}"
      '[]'
    end

    def self.check_intersections
      result = DimViewer::Intersections.run
      send_intersections_report(result)
      result
    rescue => e
      puts "DimViewer check_intersections error: #{e.message}"
      send_intersections_report([])
      []
    end

    def self.clear_intersections
      DimViewer::Intersections.clear_highlight
      send_intersections_report([])
    rescue => e
      puts "DimViewer clear_intersections error: #{e.message}"
    end

    def self.send_intersections_report(items = [])
      return unless @dialog && @dialog.visible?

      js = intersections_report_js(items)
      @dialog.execute_script("showIntersections(#{js});") rescue nil
    rescue => e
      puts "DimViewer send_intersections_report error: #{e.message}"
    end

    def self.html_content
      <<~'DIMVIEWER_HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #2b2b2b; color: #e0e0e0; padding: 12px; font-size: 13px; }
  .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; padding-bottom: 8px; border-bottom: 1px solid #444; }
  .title { font-size: 15px; font-weight: 600; color: #fff; }
  .ver { font-size: 11px; color: #888; }
  .info { background: #333; border-radius: 6px; padding: 8px 10px; margin-bottom: 10px; font-size: 12px; color: #bbb; word-break: break-word; }
  .section { margin-bottom: 12px; }
  .postitle { font-size: 12px; text-transform: uppercase; letter-spacing: .5px; color: #888; margin-bottom: 6px; }
  .row { display: flex; align-items: center; justify-content: space-between; padding: 5px 0; border-bottom: 1px solid #383838; }
  .row:last-child { border-bottom: none; }
  .lbl { color: #aaa; }
  .val { font-weight: 600; color: #fff; font-family: 'Consolas', monospace; }
  .val.x { color: #e74c3c; }
  .val.y { color: #2ecc71; }
  .val.z { color: #3498db; }
  .card { background: #333; border-radius: 6px; padding: 8px 12px; }
  .inrow { display: flex; align-items: center; gap: 6px; padding: 5px 0; }
  .inrow .tag { width: 20px; font-weight: 700; font-family: monospace; }
  .inrow .tag.x { color: #e74c3c; }
  .inrow .tag.y { color: #2ecc71; }
  .inrow .tag.z { color: #3498db; }
  input.gin, input.sin { flex: 1; background: #222; border: 1px solid #555; color: #fff; border-radius: 4px; padding: 4px 6px; font-family: monospace; font-size: 13px; }
  input.gin:focus, input.sin:focus { outline: none; border-color: #f1c40f; }
  .unit { color: #888; width: 26px; }
  .ghint { font-size: 11px; color: #888; margin-top: 6px; line-height: 1.4; }
  .ghint code { background: #222; padding: 1px 4px; border-radius: 3px; color: #f1c40f; }
  .btn { width: 100%; background: #3a3a3a; border: 1px solid #555; color: #eee; border-radius: 5px; padding: 8px; cursor: pointer; font-size: 13px; }
  .btn:hover { background: #454545; }
  .btn:disabled { opacity: .5; cursor: default; }
  .btn.active { background: #f1c40f; color: #222; border-color: #f1c40f; font-weight: 600; }
  .empty { text-align: center; color: #777; padding: 30px 10px; }
</style>
</head>
<body>
  <div class="header">
    <div class="title">Dimensions Viewer</div>
    <div class="ver">23</div>
  </div>

  <div id="content">
    <div class="empty">Выберите объект в модели</div>
  </div>

  <script>
    var lastGaps = null;
    var lastIntersectionsRows = null;
    var previewActive = false;
    var wallsCount = 0;

    function calcExpr(str) {
      if (str === null || str === undefined) return NaN;

      var s = ('' + str).trim().replace(/,/g, '.');

      if (s === '') return NaN;
      if (!/^[0-9\s\.\+\-\*\/\(\)]+$/.test(s)) return NaN;

      try {
        var v = Function('"use strict";return (' + s + ')')();
        return (typeof v === 'number' && isFinite(v)) ? v : NaN;
      } catch (e) {
        return NaN;
      }
    }

    function fmt(v) {
      if (v === null || v === undefined) return '—';
      return Number(v).toFixed(1);
    }

    function escapeHtml(s) {
      return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
    }

    function showEmpty() {
      document.getElementById('content').innerHTML =
        '<div class="empty">Выберите объект в модели</div>';
    }

    function scaleRow(axis, tag, val) {
      return '<div class="inrow"><span class="tag ' + axis + '">' + tag + '</span>' +
             '<input class="sin" data-axis="' + axis + '" value="' + fmt(val) + '">' +
             '<span class="unit">мм</span></div>';
    }

    function gapRow(dir, tag, val) {
      var disp = (val === null || val === undefined) ? '' : Number(val).toFixed(1);
      var ph = (val === null || val === undefined) ? 'нет преграды' : '';

      return '<div class="inrow"><span class="tag">' + tag + '</span>' +
             '<input class="gin" data-dir="' + dir + '" value="' + disp + '" placeholder="' + ph + '">' +
             '<span class="unit">мм</span></div>';
    }

    function showData(d, gaps, pair) {
      lastGaps = gaps;

      var html = '';

      html += '<div class="info">' + escapeHtml(d.info) + '</div>';

      html += '<div class="section"><div class="postitle">Габариты (мм)</div><div class="card">';
      html += '<div class="row"><span class="lbl">Ширина X</span><span class="val x">' + fmt(d.dx) + '</span></div>';
      html += '<div class="row"><span class="lbl">Глубина Y</span><span class="val y">' + fmt(d.dy) + '</span></div>';
      html += '<div class="row"><span class="lbl">Высота Z</span><span class="val z">' + fmt(d.dz) + '</span></div>';
      html += '</div></div>';

      if (d.lx !== null && d.lx !== undefined) {
        html += '<div class="section"><div class="postitle">Собственные размеры (мм)</div><div class="card">';
        html += '<div class="row"><span class="lbl">Локальный X</span><span class="val x">' + fmt(d.lx) + '</span></div>';
        html += '<div class="row"><span class="lbl">Локальный Y</span><span class="val y">' + fmt(d.ly) + '</span></div>';
        html += '<div class="row"><span class="lbl">Локальный Z</span><span class="val z">' + fmt(d.lz) + '</span></div>';
        html += '</div></div>';
      }

      html += '<div class="section"><div class="postitle">Свойства</div><div class="card">';
      html += '<div class="row"><span class="lbl">Объём</span><span class="val">' + (d.volume / 1e9).toFixed(4) + ' м³</span></div>';
      html += '<div class="row"><span class="lbl">Площадь</span><span class="val">' + (d.area / 1e6).toFixed(4) + ' м²</span></div>';
      html += '<div class="row"><span class="lbl">Периметр</span><span class="val">' + fmt(d.perim) + ' мм</span></div>';
      html += '</div></div>';

      if (pair) {
        html += '<div class="section"><div class="postitle">Расстояние между объектами (мм)</div><div class="card">';

        var labels = {
          xp: 'По X →',
          xn: 'По X ←',
          yp: 'По Y →',
          yn: 'По Y ←',
          zp: 'По Z ↑',
          zn: 'По Z ↓'
        };

        var any = false;

        ['xp', 'xn', 'yp', 'yn', 'zp', 'zn'].forEach(function (k) {
          if (pair[k] !== null && pair[k] !== undefined) {
            any = true;
            html += '<div class="row"><span class="lbl">' + labels[k] +
                    '</span><span class="val">' + Number(pair[k]).toFixed(1) + '</span></div>';
          }
        });

        if (!any) {
          html += '<div class="row"><span class="lbl">Нет прямого касания по осям</span></div>';
        }

        html += '</div></div>';
      }

      if (d.scalable) {
        html += '<div class="section"><div class="postitle">Задать размер по оси (мм)</div><div class="card">';
        html += scaleRow('x', 'X', d.dx);
        html += scaleRow('y', 'Y', d.dy);
        html += scaleRow('z', 'Z', d.dz);
        html += '</div>';
        html += '<div class="ghint">Введите размер и нажмите Enter — объект масштабируется по оси.<br>';
        html += 'Можно писать выражения: <code>1200-18</code>, <code>2400/2</code>.</div></div>';

        if (gaps) {
          html += '<div class="section"><div class="postitle">Зазоры до преград (мм)</div><div class="card">';
          html += gapRow('xp', 'X+', gaps.xp);
          html += gapRow('xn', 'X−', gaps.xn);
          html += gapRow('yp', 'Y+', gaps.yp);
          html += gapRow('yn', 'Y−', gaps.yn);
          html += gapRow('zp', 'Z+', gaps.zp);
          html += gapRow('zn', 'Z−', gaps.zn);
          html += '</div>';
          html += '<div class="ghint">Введите зазор и нажмите Enter — объект сдвинется до поверхности.<br>';
          html += 'Можно писать выражения: <code>1200-18</code>, <code>600+50</code>, <code>2400/2</code>.<br>';
          html += 'В превью можно кликать по подсвеченному лучу.</div></div>';
        }
      }

      html += '<div class="section">';
      html += '<button class="btn" id="previewBtn" onclick="togglePreview()">Превью лучей в 3D</button>';
      html += '</div>';

      html += '<div class="section" id="wallsSection">';
      html += '<div class="postitle">Стены-коллизии для лучей</div>';
      html += '<div id="wallsInfo" style="font-size:12px;color:#aaa;margin-bottom:6px;">Учитываются все объекты</div>';
      html += '<button class="btn" id="setWallsBtn" onclick="setWalls()">Сделать выделенное стенами</button>';
      html += '<button class="btn" id="clearWallsBtn" onclick="clearWalls()" style="margin-top:8px;">Очистить стены</button>';
      html += '</div>';

      html += '<div class="section" id="intersectionsSection">';
      html += '<div class="postitle">Проверка пересечений</div>';
      html += '<button class="btn" id="checkIntersectionsBtn" onclick="checkIntersections()">Проверить пересекающиеся объекты</button>';
      html += '<button class="btn" id="clearIntersectionsBtn" onclick="clearIntersections()" style="margin-top:8px;">Очистить подсветку</button>';
      html += '<div id="intersectionsReport" class="ghint" style="margin-top:8px;">Выберите 2 или больше групп/компонентов и нажмите проверку.</div>';
      html += '</div>';

      document.getElementById('content').innerHTML = html;

      bindInputs();
      applyPreviewState();
      applyWallsState();

      if (lastIntersectionsRows !== null) {
        showIntersections(lastIntersectionsRows);
      }
    }

    function bindInputs() {
      document.querySelectorAll('.gin').forEach(function (inp) {
        inp.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') {
            var v = calcExpr(this.value);

            if (!isNaN(v) && v >= 0 && window.sketchup && window.sketchup.set_gap) {
              window.sketchup.set_gap(this.getAttribute('data-dir'), this.value);
            }

            this.blur();
          }
        });
      });

      document.querySelectorAll('.sin').forEach(function (inp) {
        inp.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') {
            var v = calcExpr(this.value);

            if (!isNaN(v) && v > 0 && window.sketchup && window.sketchup.set_scale) {
              window.sketchup.set_scale(this.getAttribute('data-axis'), this.value);
            }

            this.blur();
          }
        });
      });
    }

    function togglePreview() {
      if (window.sketchup && window.sketchup.toggle_preview) {
        window.sketchup.toggle_preview();
      }
    }

    function setPreviewState(state) {
      previewActive = state;
      applyPreviewState();
    }

    function applyPreviewState() {
      var b = document.getElementById('previewBtn');
      if (!b) return;

      if (previewActive) {
        b.classList.add('active');
        b.innerText = 'Превью активно (выключить)';
      } else {
        b.classList.remove('active');
        b.innerText = 'Превью лучей в 3D';
      }
    }

    function setWalls() {
      if (window.sketchup && window.sketchup.set_walls) {
        window.sketchup.set_walls();
      }
    }

    function clearWalls() {
      if (window.sketchup && window.sketchup.clear_walls) {
        window.sketchup.clear_walls();
      }
    }

    function setWallsState(count) {
      wallsCount = count;
      applyWallsState();
    }

    function applyWallsState() {
      var info = document.getElementById('wallsInfo');
      var clr = document.getElementById('clearWallsBtn');

      if (!info) return;

      if (wallsCount > 0) {
        info.innerHTML = '<b style="color:#f1c40f;">Стен задано: ' + wallsCount + '</b> — лучи считаются только до них';

        if (clr) {
          clr.disabled = false;
        }
      } else {
        info.innerText = 'Учитываются все объекты';

        if (clr) {
          clr.disabled = true;
        }
      }
    }

    function checkIntersections() {
      var box = document.getElementById('intersectionsReport');

      if (box) {
        box.innerHTML = 'Проверка...';
      }

      if (window.sketchup && window.sketchup.check_intersections) {
        window.sketchup.check_intersections();
      }
    }

    function clearIntersections() {
      if (window.sketchup && window.sketchup.clear_intersections) {
        window.sketchup.clear_intersections();
      }
    }

    function showIntersections(rows) {
      var box = document.getElementById('intersectionsReport');

      lastIntersectionsRows = rows || [];

      if (!box) return;

      if (!rows || rows.length === 0) {
        box.innerHTML = '<span style="color:#2ecc71;">Пересечений не найдено.</span>';
        return;
      }

      var html = '';

      html += '<div style="color:#e74c3c;font-weight:600;margin-bottom:6px;">Найдено пересечений: ' + rows.length + '</div>';
      html += '<div class="card" style="padding:6px 8px;margin-top:6px;">';

      rows.forEach(function (r, i) {
        html += '<div style="border-bottom:1px solid #444;padding:6px 0;">';
        html += '<div><b>' + (i + 1) + '.</b> ' + escapeHtml(r.a) + '</div>';
        html += '<div style="color:#888;">↔ ' + escapeHtml(r.b) + '</div>';
        html += '<div style="color:#f1c40f;font-size:11px;margin-top:2px;">' + escapeHtml(r.mode) + '</div>';
        html += '</div>';
      });

      html += '</div>';

      box.innerHTML = html;
    }

    if (window.sketchup && window.sketchup.ready) {
      window.sketchup.ready();
    }
  </script>
</body>
</html>
DIMVIEWER_HTML
    end

    def self.show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: 'Dimensions Viewer',
        preferences_key: 'com.ivanarchitect.dimensions_viewer',
        scrollable: true,
        resizable: true,
        width: 340,
        height: 680,
        left: 200,
        top: 150,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.set_html(html_content)

      @dialog.add_action_callback('ready') do |_ctx|
        update
        notify_preview_state
        notify_walls_state
      end

      @dialog.add_action_callback('set_gap') do |_ctx, dir_key, value|
        v = parse_arithmetic(value)
        DimViewer::Rays.apply_gap(dir_key.to_sym, v) if v && v >= 0
      end

      @dialog.add_action_callback('set_scale') do |_ctx, axis_key, value|
        v = parse_arithmetic(value)
        apply_scale(axis_key, v) if v && v > 0
      end

      @dialog.add_action_callback('toggle_preview') do |_ctx|
        toggle_preview
      end

      @dialog.add_action_callback('set_walls') do |_ctx|
        DimViewer::Rays.set_walls_from_selection
        notify_walls_state
      end

      @dialog.add_action_callback('clear_walls') do |_ctx|
        DimViewer::Rays.clear_walls
        notify_walls_state
      end

      @dialog.add_action_callback('check_intersections') do |_ctx|
        check_intersections
      end

      @dialog.add_action_callback('clear_intersections') do |_ctx|
        clear_intersections
      end

      @dialog.set_on_closed do
        @dialog = nil
      end

      @dialog.show

      attach_observer
    end

    class SelObserver < Sketchup::SelectionObserver
      def onSelectionBulkChange(_sel)
        DimViewer::Main.update
      end

      def onSelectionCleared(_sel)
        DimViewer::Main.update
      end

      def onSelectionAdded(_sel, _entity)
        DimViewer::Main.update
      end

      def onSelectionRemoved(_sel, _entity)
        DimViewer::Main.update
      end
    end

    def self.attach_observer
      model = Sketchup.active_model
      return unless model

      @sel_observer ||= SelObserver.new

      model.selection.remove_observer(@sel_observer) rescue nil
      model.selection.add_observer(@sel_observer)
    end

    unless file_loaded?(__FILE__)
      menu = UI.menu('Plugins')

      menu.add_item('Dimensions Viewer') do
        show_dialog
      end

      menu.add_item('Dimensions Viewer: Проверить пересечения') do
        check_intersections
      end

      menu.add_item('Dimensions Viewer: Очистить подсветку пересечений') do
        clear_intersections
      end

      tb = UI::Toolbar.new('Dimensions Viewer')

      cmd = UI::Command.new('Dimensions Viewer') do
        show_dialog
      end

      cmd.tooltip = 'Dimensions Viewer'
      cmd.status_bar_text = 'Показать панель размеров и зазоров'
      tb.add_item(cmd)

      check_cmd = UI::Command.new('Проверить пересечения') do
        check_intersections
      end

      check_cmd.tooltip = 'Проверить пересечения'
      check_cmd.status_bar_text = 'Проверить пересечения выбранных групп/компонентов'
      tb.add_item(check_cmd)

      clear_cmd = UI::Command.new('Очистить пересечения') do
        clear_intersections
      end

      clear_cmd.tooltip = 'Очистить подсветку пересечений'
      clear_cmd.status_bar_text = 'Удалить временные красные объёмы пересечений и overlay-контур'
      tb.add_item(clear_cmd)

      tb.show

      # Контекстное меню (правая кнопка мыши).
      UI.add_context_menu_handler do |context_menu|
        context_menu.add_item('Скрыть всё кроме выделенных объектов') do
          DimViewer::HideOthers.hide_all_except_selected
        end

        context_menu.add_item('Показать всё') do
          DimViewer::HideOthers.unhide_all
        end
      end

      file_loaded(__FILE__)
    end

  end
end
