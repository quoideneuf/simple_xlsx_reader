require "simple_xlsx_reader/version"
require 'nokogiri'
require 'zip/zip'
require 'zip/zipfilesystem'
require 'date'

module SimpleXlsxReader
  def self.open(file_path)
    Document.new(file_path).to_hash
  end

  class Document
    attr_reader :file_path

    def initialize(file_path)
      @file_path = file_path
    end

    def sheets
      @sheets ||= Mapper.new(xml).load_sheets
    end

    def to_hash
      sheets.inject({}) {|acc, sheet| acc[sheet.name] = sheet.rows; acc}
    end

    def xml
      Xml.load(file_path)
    end

    class Xml
      attr_accessor :workbook, :shared_strings, :sheets, :styles

      def self.load(file_path)
        self.new.tap do |xml|
          Zip::ZipFile.open(file_path) do |zip|
            xml.workbook       = Nokogiri::XML(zip.read('xl/workbook.xml'))
            xml.shared_strings = Nokogiri::XML(zip.read('xl/sharedStrings.xml'))
            xml.styles         = Nokogiri::XML(zip.read('xl/styles.xml'))

            xml.sheets = []
            i = 0
            loop do
              i += 1
              break if !zip.file.file?("xl/worksheets/sheet#{i}.xml")

              xml.sheets <<
                Nokogiri::XML(zip.read("xl/worksheets/sheet#{i}.xml"))
            end
          end
        end
      end
    end

    class Mapper < Struct.new(:xml)
      def load_sheets
        sheet_toc.map do |(sheet_name, sheet_number)|
          Sheet.new(sheet_name, rows_on_sheet(sheet_number))
        end
      end

      # Table of contents for the sheets, ex. {'Authors' => 0, ...}
      def sheet_toc
        xml.workbook.xpath('/xmlns:workbook/xmlns:sheets/xmlns:sheet').
          inject({}) do |acc, sheet|

          acc[sheet.attributes['name'].value] =
            sheet.attributes['sheetId'].value.to_i - 1 # keep things 0-indexed

          acc
        end
      end

      def rows_on_sheet(number)
        xml.sheets[number].
          xpath("/xmlns:worksheet/xmlns:sheetData/xmlns:row").map do |xrow|

          xrow.children.map do |xcell|
            type = xcell.attributes['t'] &&
                   xcell.attributes['t'].value
            # If not the above, attempt to determine from a custom style
            type ||= xcell.attributes['s'] &&
                     style_types[xcell.attributes['s'].value.to_i]

            self.class.cast(xcell.text, type, shared_strings: shared_strings)
          end
        end
      end

      # Excel doesn't record types for some cells, only its display style, so
      # we have to back out the type from that style.
      #
      # Some of these styles can be determined from a known set (see NumFmtMap), 
      # while others are 'custom' and we have to make a best guess.
      #
      # This is the array of types corresponding to the styles a spreadsheet
      # uses, and includes both the known style types and the custom styles.
      #
      # Note that the xml sheet cells that use this don't reference the
      # numFmtId, but instead the array index of a style in the stored list of
      # only the styles used in the spreadsheet (which can be either known or
      # custom). Hence this style types array, rather than a map of numFmtId to
      # type.
      def style_types
        @style_types ||=
          xml.styles.xpath('/xmlns:styleSheet/xmlns:cellXfs/xmlns:xf').map {|xstyle|
            style_type_by_num_fmt_id(xstyle.attributes['numFmtId'].value)}
      end

      # Finds the type we think a style is; For example, fmtId 14 is a date
      # style, so this would return :date
      def style_type_by_num_fmt_id(id)
        return nil if id.nil?

        id = id.to_i
        if id > 164 # custom style, arg!
          custom_style_types[id]
        else # we should know this one
          NumFmtMap[id]
        end
      end

      # Map of (numFmtId > 164) (custom styles) to our best guess at the type
      # ex. {165 => :date_time}
      def custom_style_types
        @custom_style_types ||=
          xml.styles.xpath('/xmlns:styleSheet/xmlns:numFmts/xmlns:numFmt').
          inject({}) do |acc, xstyle|

          acc[xstyle.attributes['numFmtId'].value.to_i] =
            determine_custom_style_type(xstyle.attributes['formatCode'].value)

          acc
        end
      end

      # This is the least deterministic part of reading xlsx files. Due to
      # custom styles, you can't know for sure when a date is a date other than
      # looking at its format and gessing. It's not impossible to guess right,
      # though.
      #
      # http://stackoverflow.com/questions/4948998/determining-if-an-xlsx-cell-is-date-formatted-for-excel-2007-spreadsheets
      def determine_custom_style_type(string)
        return :float if string[0] == '_'
        return :float if string[0] == ' 0'

        # Looks for one of ymdhis outside of meta-stuff like [Red]
        return :date_time if string =~ /(^|\])[^\[]*[ymdhis]/i

        return :unsupported
      end

      ##
      # The heart of typecasting. The ruby type is determined either explicitly
      # from the cell xml or implicitly from the cell style, and this
      # method expects that work to have been done already. This, then,
      # takes the type we determined it to be and casts the cell value
      # to that type.
      #
      # types:
      # - s: shared string (see #shared_string)
      # - n: number (cast to a float)
      # - b: boolean
      # - str: string
      # - inlineStr: string
      # - ruby symbol: for when type has been determined by style
      #
      # options:
      # - shared_strings: needed for 's' (shared string) type
      def self.cast(value, type, options = {})
        return nil if value.nil? || value.empty?

        case type

        ##
        # There are few built-in types
        ##

        when 's' # shared string
          options[:shared_strings][value.to_i]
        when 'n' # number
          value.to_f
        when 'b'
          value.to_i == 1
        when 'str'
          value
        when 'inlineStr'
          value

        ##
        # Type can also be determined by a style,
        # detected earlier and cast here by its standardized symbol
        ##

        when :string, :unsupported
          value
        when :fixnum
          value.to_i
        when :float
          value.to_f
        when :percentage
          value.to_f / 100
        # the trickiest. note that  all these formats can vary on
        # whether they actually contain a date, time, or datetime.
        when :date, :time, :date_time
          days_since_1900, fraction_of_24 = value.split('.')

          # http://stackoverflow.com/questions/10559767/how-to-convert-ms-excel-date-from-float-to-date-format-in-ruby
          date = Date.new(1899, 12, 30) + days_since_1900.to_i

          if fraction_of_24 # there is a time associated
            fraction_of_24 = "0.#{fraction_of_24}".to_f
            military       = fraction_of_24 * 24
            hour           = military.truncate
            minute         = ((military % 1) * 60).truncate

            return Time.utc(date.year, date.month, date.day, hour, minute)
          else
            return date
          end
        when :bignum
          if defined?(BigDecimal)
            BigDecimal.new(value)
          else
            value.to_f
          end

        ##
        # Beats me
        ##

        else
          value
        end
      end

      # Map of non-custom numFmtId to casting symbol
      NumFmtMap = {
        0  => :string,         # General
        1  => :fixnum,         # 0
        2  => :float,          # 0.00
        3  => :fixnum,         # #,##0
        4  => :float,          # #,##0.00
        5  => :unsupported,    # $#,##0_);($#,##0)
        6  => :unsupported,    # $#,##0_);[Red]($#,##0)
        7  => :unsupported,    # $#,##0.00_);($#,##0.00)
        8  => :unsupported,    # $#,##0.00_);[Red]($#,##0.00)
        9  => :percentage,     # 0%
        10 => :percentage,     # 0.00%
        11 => :bignum,         # 0.00E+00
        12 => :unsupported,    # # ?/?
        13 => :unsupported,    # # ??/??
        14 => :date,           # mm-dd-yy
        15 => :date,           # d-mmm-yy
        16 => :date,           # d-mmm
        17 => :date,           # mmm-yy
        18 => :time,           # h:mm AM/PM
        19 => :time,           # h:mm:ss AM/PM
        20 => :time,           # h:mm
        21 => :time,           # h:mm:ss
        22 => :date_time,      # m/d/yy h:mm
        37 => :unsupported,    # #,##0 ;(#,##0)
        38 => :unsupported,    # #,##0 ;[Red](#,##0)
        39 => :unsupported,    # #,##0.00;(#,##0.00)
        40 => :unsupported,    # #,##0.00;[Red](#,##0.00)
        45 => :time,           # mm:ss
        46 => :time,           # [h]:mm:ss
        47 => :time,           # mmss.0
        48 => :bignum,         # ##0.0E+0
        49 => :unsupported     # @
      }

      # For performance reasons, excel uses an optional SpreadsheetML feature
      # that puts all strings in a separate xml file, and then references
      # them by their index in that file.
      def shared_strings
        @shared_strings ||= xml.shared_strings.
          xpath('/xmlns:sst/xmlns:si/xmlns:t/text()').map(&:to_s)
      end

    end

    class Sheet < Struct.new(:name, :rows)
      def headers
        rows[0]
      end

      def data
        rows[1..-1]
      end

      def to_a
        data
      end
    end
  end
end