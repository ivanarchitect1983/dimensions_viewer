module DimViewer
  module Main

    VERSION = 11  # <- bump this on every change; the number is shown in the window corner

    # TODO: replace with the real project repository URL
    GITHUB_URL = 'https://github.com/ivanarchitect1983/dimensions_viewer'

    @dialog = nil

    # Point -> [x,y,z] pure Float in inches.
    def self.pt_xyz(point3d)
      a = point3d.to_a
      [a[0].to_f, a[1].to_f, a[2].to_f]
    end

    # =====================================================================
    #  POINT COLLECTION (Float, inches)
    # =====================================================================

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
        entity.vertices.each { |v| pts << pt_xyz(v.position.transform(transform)) }
      when Sketchup::Face
        entity.vertices.each { |v| pts << pt_xyz(v.position.transform(transform)) }
      when Sketchup::Vertex
        pts << pt_xyz(entity.position.transform(transform))
      when Sketchup::CLine
        pts << pt_xyz(entity.start.transform(transform)) if entity.start
        pts << pt_xyz(entity.end.transform(transform))   if entity.end
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

    # =====================================================================
    #  LOCAL DIMENSIONS — raw coordinate difference of internal geometry.
    #  The model's internal units are numerically equal to millimeters,
    #  so the returned values are ALREADY millimeters (in JS they are NOT
    #  multiplied by 25.4 — mmRaw() is used).
    # =====================================================================

    def self.local_bounds(entity)
      return nil unless entity.is_a?(Sketchup::Group) ||
                        entity.is_a?(Sketchup::ComponentInstance)
      pts = []
      ents = entity.is_a?(Sketchup::Group) ?
             entity.entities : entity.definition.entities
      ents.each { |e| collect_points(e, Geom::Transformation.new, pts) }
      b = bounds_of(pts)
      return nil unless b
      min, max = b
      # raw difference is already in millimeters:
      [max[0] - min[0], max[1] - min[1], max[2] - min[2]]
    rescue => e
      puts "DimViewer local_bounds error: #{e.message}"
      nil
    end

    # =====================================================================
    #  ROTATION CHECK
    # =====================================================================

    # true if the group/component is rotated relative to the world axes.
    # We compare the transformation axis directions with the world X/Y/Z.
    def self.rotated?(entity)
      return false unless entity.is_a?(Sketchup::Group) ||
                          entity.is_a?(Sketchup::ComponentInstance)
      t = entity.transformation
      xa = t.xaxis.normalize
      ya = t.yaxis.normalize
      za = t.zaxis.normalize
      # If the object is not rotated, the axes match X_AXIS/Y_AXIS/Z_AXIS
      # => dot product ≈ ±1. Otherwise — rotated.
      tol = 0.9999
      (xa % X_AXIS).abs < tol ||
      (ya % Y_AXIS).abs < tol ||
      (za % Z_AXIS).abs < tol
    rescue => e
      puts "DimViewer rotated? error: #{e.message}"
      false
    end

    # =====================================================================
    #  VOLUME AND AREA (Float, inch³ / inch²)
    # =====================================================================

    def self.calc_volume_area(entity, transform)
      volume = 0.0; area = 0.0
      return [0.0, 0.0] unless entity && entity.valid?
      case entity
      when Sketchup::Group
        t = transform * entity.transformation
        entity.entities.each { |e| v,a = calc_volume_area(e,t); volume+=v; area+=a }
      when Sketchup::ComponentInstance
        t = transform * entity.transformation
        entity.definition.entities.each { |e| v,a = calc_volume_area(e,t); volume+=v; area+=a }
      when Sketchup::Face
        mesh = entity.mesh(0)
        pts = mesh.points.map { |p| pt_xyz(p.transform(transform)) }
        mesh.polygons.each do |poly|
          p1 = pts[poly[0].abs-1]; p2 = pts[poly[1].abs-1]; p3 = pts[poly[2].abs-1]
          ax,ay,az = p1; bx,by,bz = p2; cx,cy,cz = p3
          ux=bx-ax; uy=by-ay; uz=bz-az
          vx=cx-ax; vy=cy-ay; vz=cz-az
          crx=uy*vz-uz*vy; cry=uz*vx-ux*vz; crz=ux*vy-uy*vx
          area += Math.sqrt(crx*crx+cry*cry+crz*crz)/2.0
          cx2=by*cz-bz*cy; cy2=bz*cx-bx*cz; cz2=bx*cy-by*cx
          volume += (ax*cx2+ay*cy2+az*cz2)/6.0
        end
      end
      [volume, area]
    rescue => e
      puts "DimViewer calc_volume_area error: #{e.message}"
      [volume, area]
    end

    # =====================================================================
    #  PERIMETER (Float, inches)
    # =====================================================================

    def self.calc_perimeter(entity, transform)
      return 0.0 unless entity && entity.valid?
      length = 0.0
      case entity
      when Sketchup::Edge
        a = pt_xyz(entity.start.position.transform(transform))
        b = pt_xyz(entity.end.position.transform(transform))
        dx=b[0]-a[0]; dy=b[1]-a[1]; dz=b[2]-a[2]
        length += Math.sqrt(dx*dx+dy*dy+dz*dz)
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

    # =====================================================================
    #  WINDOW UPDATE — send ONLY Float values, WITHOUT units
    # =====================================================================

    def self.update
      return unless @dialog && @dialog.visible?
      begin
        model = Sketchup.active_model
        return unless model
        sel = model.selection

        # Do NOT apply edit_transform: the selected geometry is already in the
        # current context coordinates. Identity matrix = correct dimensions.
        edit_t = Geom::Transformation.new

        if sel.empty?
          send_empty
          return
        end

        gmin = nil; gmax = nil
        total_volume = 0.0; total_area = 0.0; total_perim = 0.0

        sel.each do |e|
          next unless e && e.valid?
          wb = world_bounds(e, edit_t)
          if wb
            emin, emax = wb
            if gmin.nil?
              gmin = emin.dup; gmax = emax.dup
            else
              3.times do |i|
                gmin[i] = emin[i] if emin[i] < gmin[i]
                gmax[i] = emax[i] if emax[i] > gmax[i]
              end
            end
          end
          v, a = calc_volume_area(e, edit_t)
          total_volume += v; total_area += a
          total_perim  += calc_perimeter(e, edit_t)
        end

        if gmin.nil?
          send_empty
          return
        end

        # World dimensions (SketchUp inches -> ×25.4 in JS):
        dx = gmax[0] - gmin[0]
        dy = gmax[1] - gmin[1]
        dz = gmax[2] - gmin[2]

        count = sel.length
        info  = describe_selection(sel, count)

        # Local dimensions — already in millimeters (mmRaw in JS, no ×25.4).
        # Shown only for a single rotated object.
        lx = ly = lz = nil
        if count == 1 && rotated?(sel.first)
          lb = local_bounds(sel.first)
          if lb
            lx, ly, lz = lb
          end
        end

        payload = {
          dx: dx, dy: dy, dz: dz,                  # inches (×25.4 in JS)
          area_in2: total_area,                    # inch²
          vol_in3:  total_volume,                  # inch³
          perim_in: total_perim,                   # inches
          lx: lx, ly: ly, lz: lz,                  # MM (mmRaw in JS) or null
          info: info,
          empty: false
        }
        send_payload(payload)
      rescue => e
        puts "DimViewer update error: #{e.message}"
        puts e.backtrace.join("\n")
      end
    end

    def self.send_empty
      send_payload({ empty: true, info: 'Nothing selected' })
    end

    def self.describe_selection(sel, count)
      groups = comps = faces = edges = others = 0
      sel.each do |e|
        case e
        when Sketchup::Group then groups += 1
        when Sketchup::ComponentInstance then comps += 1
        when Sketchup::Face then faces += 1
        when Sketchup::Edge then edges += 1
        else others += 1
        end
      end
      if count == 1
        e = sel.first
        case e
        when Sketchup::Group
          n = e.name.to_s.strip
          n.empty? ? 'Group' : "Group: #{n}"
        when Sketchup::ComponentInstance
          "Component: #{e.definition.name}"
        when Sketchup::Face then 'Face'
        when Sketchup::Edge then 'Edge'
        else 'Object'
        end
      else
        parts = []
        parts << "#{groups} grp."   if groups > 0
        parts << "#{comps} comp."   if comps  > 0
        parts << "#{faces} face."   if faces  > 0
        parts << "#{edges} edge."   if edges  > 0
        parts << "#{others} other." if others > 0
        "#{count}: " + parts.join(", ")
      end
    end

    # JSON serialization: Float, integer, string, nil, bool
    def self.to_json_value(v)
      case v
      when Float
        v.finite? ? v.to_s : 'null'
      when Integer   then v.to_s
      when String    then v.inspect
      when true      then 'true'
      when false     then 'false'
      when nil       then 'null'
      else v.inspect
      end
    end

    def self.send_payload(data)
      return unless @dialog
      json = "{" + data.map { |k, v| "#{k}:#{to_json_value(v)}" }.join(",") + "}"
      @dialog.execute_script("updateDims(#{json});")
    end

    # =====================================================================
    #  HTML  (unit conversion is done HERE, in JS)
    # =====================================================================

    def self.html_content
      <<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <style>
          body { font-family:'Segoe UI',Tahoma,sans-serif; margin:0; padding:12px;
                 background:#2b2b2b; color:#e0e0e0; user-select:none; }
          .info { font-size:12px; color:#aaa; margin-bottom:12px; padding-bottom:8px;
                  border-bottom:1px solid #444; white-space:nowrap; overflow:hidden;
                  text-overflow:ellipsis; }
          .row { display:flex; align-items:center; margin:6px 0; font-size:16px; }
          .axis { width:28px; font-weight:bold; text-align:center; border-radius:4px;
                  margin-right:10px; padding:2px 0; color:#fff; }
          .x { background:#e74c3c; } .y { background:#2ecc71; } .z { background:#3498db; }
          .val { font-family:'Consolas',monospace; }
          .section { margin-top:12px; padding-top:10px; border-top:1px solid #444; }
          .section .row { font-size:14px; }
          .label { width:110px; color:#f1c40f; margin-right:10px; }
          .label.vol { color:#9b59b6; } .label.per { color:#1abc9c; }
          .label.local { color:#e67e22; }
          .btn { margin-top:14px; width:100%; padding:8px; background:#3a3a3a;
                 color:#e0e0e0; border:1px solid #555; border-radius:5px;
                 cursor:pointer; font-size:13px; }
          .btn:hover { background:#4a4a4a; }
          .btn.copied { background:#27ae60; border-color:#27ae60; }
          .ver { position:fixed; top:6px; right:10px; font-size:10px;
                 color:#666; text-decoration:none; z-index:100;
                 padding:2px 6px; border-radius:4px; transition:all .15s; }
          .ver:hover { color:#3498db; background:#333; }
        </style>
      </head>
      <body>
        <a class="ver" id="verLink" href="#" title="Open project repository">v#{VERSION}</a>
        <div class="info" id="info" title="">Nothing selected</div>
        <div class="row"><span class="axis x">X</span><span class="val" id="vx">—</span></div>
        <div class="row"><span class="axis y">Y</span><span class="val" id="vy">—</span></div>
        <div class="row"><span class="axis z">Z</span><span class="val" id="vz">—</span></div>
        <div class="section">
          <div class="row"><span class="label local">Local (XYZ)</span><span class="val" id="vlocal">—</span></div>
          <div class="row"><span class="label">Area</span><span class="val" id="varea">—</span></div>
          <div class="row"><span class="label vol">Volume</span><span class="val" id="vvol">—</span></div>
          <div class="row"><span class="label per">Perimeter</span><span class="val" id="vperim">—</span></div>
        </div>
        <button class="btn" id="copyBtn" onclick="copyAll()">📋 Copy</button>
        <script>
          // === CONVERSION CONSTANTS (single source of truth!) ===
          var MM_PER_INCH = 25.4;
          var M_PER_INCH  = 0.0254;

          // world dimensions arrive in SketchUp "inches" -> multiply by 25.4
          function mm(inch)  { return (inch * MM_PER_INCH).toFixed(1) + ' mm'; }

          // local dimensions arrive ALREADY in millimeters -> do NOT multiply
          function mmRaw(v)  { return v.toFixed(1) + ' mm'; }

          function m2(in2)   {
            if (in2 === null || in2 <= 1e-9) return '—';
            return (in2 * M_PER_INCH * M_PER_INCH).toFixed(4) + ' m²';
          }
          function m3(in3)   {
            if (in3 === null) return '—';
            var v = Math.abs(in3);
            if (v <= 1e-9) return '—';
            return (v * M_PER_INCH * M_PER_INCH * M_PER_INCH).toFixed(6) + ' m³';
          }

          var current = {};

          function updateDims(d) {
            current = d;
            var info = document.getElementById('info');

            if (d.empty) {
              document.getElementById('vx').innerText     = '—';
              document.getElementById('vy').innerText     = '—';
              document.getElementById('vz').innerText     = '—';
              document.getElementById('vvol').innerText   = '—';
              document.getElementById('varea').innerText  = '—';
              document.getElementById('vperim').innerText = '—';
              document.getElementById('vlocal').innerText = '—';
              info.innerText = d.info; info.title = d.info;
              return;
            }

            document.getElementById('vx').innerText = mm(d.dx);
            document.getElementById('vy').innerText = mm(d.dy);
            document.getElementById('vz').innerText = mm(d.dz);
            document.getElementById('varea').innerText  = m2(d.area_in2);
            document.getElementById('vvol').innerText   = m3(d.vol_in3);
            document.getElementById('vperim').innerText =
              (d.perim_in && d.perim_in > 1e-9) ? mm(d.perim_in) : '—';

            var local = '—';
            if (d.lx !== null && d.ly !== null && d.lz !== null) {
              local = mmRaw(d.lx) + ' × ' + mmRaw(d.ly) + ' × ' + mmRaw(d.lz);
            }
            document.getElementById('vlocal').innerText = local;

            info.innerText = d.info; info.title = d.info;
          }

          function buildText() {
            var l = [];
            l.push(current.info || '');
            if (!current.empty) {
              l.push('X: ' + mm(current.dx));
              l.push('Y: ' + mm(current.dy));
              l.push('Z: ' + mm(current.dz));
              if (current.lx !== null && current.lx !== undefined)
                l.push('Local (XYZ): ' + mmRaw(current.lx) + ' × ' + mmRaw(current.ly) + ' × ' + mmRaw(current.lz));
              if (m2(current.area_in2) !== '—') l.push('Area: ' + m2(current.area_in2));
              if (m3(current.vol_in3)  !== '—') l.push('Volume: ' + m3(current.vol_in3));
              if (current.perim_in && current.perim_in > 1e-9) l.push('Perimeter: ' + mm(current.perim_in));
            }
            return l.join('\\n');
          }

          function copyAll() {
            var text = buildText();
            var btn = document.getElementById('copyBtn');
            function showCopied() {
              btn.classList.add('copied'); btn.innerText = '✓ Copied';
              setTimeout(function(){ btn.classList.remove('copied'); btn.innerText = '📋 Copy'; }, 1200);
            }
            function fallbackCopy(t) {
              var ta = document.createElement('textarea');
              ta.value = t; document.body.appendChild(ta); ta.select();
              try { document.execCommand('copy'); showCopied(); } catch(e) {}
              document.body.removeChild(ta);
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).then(showCopied, function(){ fallbackCopy(text); });
            } else { fallbackCopy(text); }
          }

          // Click on the version -> open GitHub in the external browser
          var verLink = document.getElementById('verLink');
          if (verLink) {
            verLink.addEventListener('click', function(e) {
              e.preventDefault();
              if (window.sketchup && window.sketchup.open_github) {
                window.sketchup.open_github();
              }
            });
          }

          if (window.sketchup && window.sketchup.ready) { window.sketchup.ready(); }
        </script>
      </body>
      </html>
      HTML
    end

    # =====================================================================
    #  OBSERVERS
    # =====================================================================

    class SelObserver < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel); DimViewer::Main.update; end
      def onSelectionCleared(sel);    DimViewer::Main.update; end
      def onSelectionAdded(sel, e);   DimViewer::Main.update; end
      def onSelectionRemoved(sel, e); DimViewer::Main.update; end
    end

    class ToolsObserver < Sketchup::ToolsObserver
      def onActiveToolChanged(tools, tool_name, tool_id); DimViewer::Main.update; end
    end

    # Recalculate on Undo / Redo and any geometry change
    class ModObserver < Sketchup::ModelObserver
      def onTransactionUndo(model);    DimViewer::Main.delayed_update; end
      def onTransactionRedo(model);    DimViewer::Main.delayed_update; end
      def onTransactionCommit(model);  DimViewer::Main.delayed_update; end
    end

    class AppObserver < Sketchup::AppObserver
      def onNewModel(model);  DimViewer::Main.attach_observers(model); DimViewer::Main.update; end
      def onOpenModel(model); DimViewer::Main.attach_observers(model); DimViewer::Main.update; end
    end

    # Deferred call: after Undo the geometry may update asynchronously,
    # so we recalculate via a timer to get the actual state.
    def self.delayed_update
      UI.start_timer(0, false) { DimViewer::Main.update }
    rescue
      update
    end

    # HARD removal of all old observers of our type + reinstall
    def self.attach_observers(model)
      return unless model
      ObjectSpace.each_object(SelObserver)   { |o| model.selection.remove_observer(o) rescue nil }
      ObjectSpace.each_object(ToolsObserver) { |o| model.tools.remove_observer(o)     rescue nil }
      ObjectSpace.each_object(ModObserver)   { |o| model.remove_observer(o)           rescue nil }

      @sel_observer   = SelObserver.new
      @tools_observer = ToolsObserver.new
      @mod_observer   = ModObserver.new
      model.selection.add_observer(@sel_observer)
      model.tools.add_observer(@tools_observer)
      model.add_observer(@mod_observer)
    rescue => e
      puts "DimViewer attach_observers error: #{e.message}"
    end

    # =====================================================================
    #  WINDOW
    # =====================================================================

    def self.show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end
      @dialog = UI::HtmlDialog.new(
        dialog_title:    'Dimensions',
        preferences_key: 'DimViewer_Dialog',
        scrollable:      false, resizable: true,
        width: 270, height: 380, min_width: 230, min_height: 330,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.add_action_callback('ready') { |ctx| update }
      @dialog.add_action_callback('open_github') do |ctx|
        UI.openURL(GITHUB_URL)
      end
      @dialog.set_html(html_content)
      @dialog.show
      update
    end

    # =====================================================================
    #  ИНИЦИАЛИЗАЦИЯ
    # =====================================================================

    puts "DimViewer loading v#{VERSION} from #{__FILE__}"

    unless file_loaded?(__FILE__)
      menu = UI.menu('Plugins')
      menu.add_item('Dimensions Viewer') { show_dialog }
      @app_observer ||= AppObserver.new
      Sketchup.add_observer(@app_observer)
      file_loaded(__FILE__)
    end

    # reinstall the observers on EVERY load
    attach_observers(Sketchup.active_model)

  end # module Main
end # module DimViewer