module DimViewer
  module HideOthers

    def self.model
      Sketchup.active_model
    end

    def self.selection
      model.selection
    end

    # Объекты текущего контекста, которые можно скрывать.
    def self.hideable_entities
      model.active_entities.select do |e|
        e.respond_to?(:hidden=) &&
          (e.is_a?(Sketchup::Group) ||
           e.is_a?(Sketchup::ComponentInstance) ||
           e.is_a?(Sketchup::Edge) ||
           e.is_a?(Sketchup::Face))
      end
    rescue => e
      puts "DimViewer HideOthers hideable_entities error: #{e.message}"
      []
    end

    def self.hide_all_except_selected
      sel = selection

      if sel.empty?
        UI.messagebox('Выберите хотя бы один объект.')
        return
      end

      selected_ids = {}
      sel.each do |e|
        selected_ids[e.entityID] = true if e.respond_to?(:entityID)
      end

      model.start_operation('Скрыть всё кроме выделенных', true)

      begin
        hideable_entities.each do |entity|
          next unless entity && entity.valid?
          next if selected_ids.key?(entity.entityID)

          entity.hidden = true
        end

        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "DimViewer HideOthers hide error: #{e.message}"
      end

      model.active_view.invalidate
    rescue => e
      puts "DimViewer HideOthers hide_all_except_selected error: #{e.message}"
    end

    def self.unhide_all
      model.start_operation('Показать всё', true)

      begin
        model.active_entities.each do |entity|
          next unless entity && entity.valid?

          entity.hidden = false if entity.respond_to?(:hidden=)
        end

        model.commit_operation
      rescue => e
        model.abort_operation rescue nil
        puts "DimViewer HideOthers unhide error: #{e.message}"
      end

      model.active_view.invalidate
    rescue => e
      puts "DimViewer HideOthers unhide_all error: #{e.message}"
    end

    def self.has_selection?
      !selection.empty?
    rescue
      false
    end

  end
end