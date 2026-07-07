require 'sketchup.rb'
require 'extensions.rb'

module DimViewer
  PLUGIN_DIR = File.join(File.dirname(__FILE__), 'dimensions_viewer')

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new('Dimensions Viewer', File.join(PLUGIN_DIR, 'main.rb'))
    ext.description = 'Displays the dimensions of the selected object along the world axes.'
    ext.version     = '12'
    ext.creator     = 'Sitnikov Ivan'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end