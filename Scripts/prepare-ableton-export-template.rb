#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "rexml/document"
require "rexml/formatters/default"
require "rexml/xpath"
require "zlib"

abort "usage: prepare-ableton-export-template.rb one-pad.adg filter-rack.adg output.adg" unless ARGV.length == 3

one_pad_path, filter_rack_path, output_path = ARGV

def read_adg(path)
  Zlib::GzipReader.open(path) { |reader| REXML::Document.new(reader.read) }
end

def set_value(node, value)
  node.attributes["Value"] = value.to_s if node
end

document = read_adg(one_pad_path)
filter_document = read_adg(filter_rack_path)

branches = REXML::XPath.match(
  document,
  "/Ableton/GroupDevicePreset/BranchPresets/DrumBranchPreset"
)
abort "one-pad template must contain exactly one DrumBranchPreset" unless branches.length == 1
branch = branches.first
branch.attributes["Id"] = "0"

base_filter = REXML::XPath.first(branch, ".//MultiSampler/Filter")
enabled_filter = REXML::XPath.first(
  filter_document,
  "/Ableton/GroupDevicePreset/BranchPresets/DrumBranchPreset[1]//MultiSampler/Filter"
)
abort "one-pad template has no Sampler Filter node" unless base_filter
abort "filter rack has no enabled Sampler Filter node" unless enabled_filter
filter_clone = REXML::Document.new(enabled_filter.to_s).root
base_filter.parent.insert_after(base_filter, filter_clone)
base_filter.parent.delete_element(base_filter)

set_value(REXML::XPath.first(document, "//DrumGroupDevice/UserName"), "AKAI S950 Drum Rack")
set_value(REXML::XPath.first(branch, "Name"), "AKAI SAMPLE")
set_value(REXML::XPath.first(branch, ".//MultiSampler/UserName"), "")

part = REXML::XPath.first(branch, ".//MultiSamplePart")
abort "one-pad template has no MultiSamplePart" unless part
part.attributes["Id"] = "0"
set_value(REXML::XPath.first(part, "Name"), "AKAI SAMPLE")
set_value(REXML::XPath.first(part, "RootKey"), 60)
set_value(REXML::XPath.first(part, "Detune"), 0)
set_value(REXML::XPath.first(part, "SampleStart"), 0)
set_value(REXML::XPath.first(part, "SampleEnd"), 1)
set_value(REXML::XPath.first(part, "SustainLoop/Start"), 0)
set_value(REXML::XPath.first(part, "SustainLoop/End"), 1)
set_value(REXML::XPath.first(part, "ReleaseLoop/Start"), 0)
set_value(REXML::XPath.first(part, "ReleaseLoop/End"), 1)

REXML::XPath.each(part, ".//SampleRef//FileRef") do |file_ref|
  set_value(REXML::XPath.first(file_ref, "RelativePathType"), 0)
  set_value(REXML::XPath.first(file_ref, "RelativePath"), "Samples/AKAI SAMPLE.wav")
  set_value(REXML::XPath.first(file_ref, "Path"), "/AKAI-S950-EXPORT/Samples/AKAI SAMPLE.wav")
  set_value(REXML::XPath.first(file_ref, "OriginalFileSize"), 0)
  set_value(REXML::XPath.first(file_ref, "OriginalCrc"), 0)
  set_value(REXML::XPath.first(file_ref, "SourceHint"), "")
end
set_value(REXML::XPath.first(part, ".//SampleRef/LastModDate"), 0)
set_value(REXML::XPath.first(part, ".//SampleRef/DefaultDuration"), 2)
set_value(REXML::XPath.first(part, ".//SampleRef/DefaultSampleRate"), 44_100)
REXML::XPath.each(part, ".//SampleRef//BrowserContentPath") do |node|
  set_value(node, "")
end

set_value(REXML::XPath.first(branch, "ZoneSettings/ReceivingNote"), 60)
set_value(REXML::XPath.first(branch, "ZoneSettings/SendingNote"), 60)
set_value(REXML::XPath.first(branch, "ZoneSettings/ChokeGroup"), 1)

xml = String.new
REXML::Formatters::Default.new.write(document, xml)
abort "sanitized template still contains a user home path" if xml.match?(%r{/Users/[^/]+/})

FileUtils.mkdir_p(File.dirname(output_path))
Zlib::GzipWriter.open(output_path) do |writer|
  writer.mtime = 0
  writer.orig_name = ""
  writer.write(xml)
end

puts output_path
