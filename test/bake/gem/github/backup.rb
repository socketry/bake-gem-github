# frozen_string_literal: true

# Released under the MIT License.
# Copyright, 2026, by Samuel Williams.

require "bake/gem/github/backup"
require "sus/fixtures/temporary_directory_context"

describe Bake::Gem::GitHub::Backup do
	include Sus::Fixtures::TemporaryDirectoryContext
	
	let(:path) {File.join(root, "release.tar")}
	
	it "preserves binary package bytes and the receipt together" do
		files = {"example.gem" => "\x00\xffpackage".b, "release.json" => "{}"}
		files.each{|name, content| File.binwrite(File.join(root, name), content)}
		subject.write(path, files.keys.map{|name| File.join(root, name)})
		expect(subject.read(path, files.keys)).to be == files
	end
	
	it "rejects an incomplete backup" do
		File.write(File.join(root, "example.gem"), "package")
		subject.write(path, [File.join(root, "example.gem")])
		expect{subject.read(path, ["example.gem", "release.json"])}.to raise_exception(RuntimeError, message: be =~ /incomplete/)
	end
	
	[["../outside"], ["/absolute"], ["example.gem", "example.gem"]].each do |entries|
		it "rejects unexpected or duplicate filenames", unique: entries do
			File.open(path, "wb") do |file|
				Gem::Package::TarWriter.new(file) do |archive|
					entries.each{|name| archive.add_file(name, 0644){|entry| entry.write("bytes")}}
				end
			end
			expect{subject.read(path, ["example.gem"])}.to raise_exception(RuntimeError, message: be =~ /Unexpected release backup entry/)
		end
	end
	
	it "rejects links in place of release files" do
		File.open(path, "wb") do |file|
			Gem::Package::TarWriter.new(file){|archive| archive.add_symlink("example.gem", "../outside", 0644)}
		end
		expect{subject.read(path, ["example.gem"])}.to raise_exception(RuntimeError, message: be =~ /Unexpected release backup entry/)
	end
end
