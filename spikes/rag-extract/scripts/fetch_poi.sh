#!/bin/sh
# Public test files from Apache POI's test-data (Apache-2.0), used as the
# legacy .xls/.ppt and real-world .xlsx/.pptx samples. usage: fetch_poi.sh OUTDIR
set -e
mkdir -p "$1"
cd "$1"
BASE="https://raw.githubusercontent.com/apache/poi/trunk/test-data"
for f in basic_test_ppt_file next_test_ppt_file with_textbox WithComments bullets headers_footers \
         54880_chinese bug55902-mixedFontChineseCharacters numbers text_shapes 38256 Password_Protected-hello empty \
         clusterfuzz-testcase-minimized-POIHSLFFuzzer-6614960949821440 clusterfuzz-testcase-minimized-POIHSLFFuzzer-4624961081573376 \
         clusterfuzz-testcase-minimized-POIFuzzer-5681320547975168 57272_corrupted_usereditatom; do
    curl -sf -m 60 -o "$f.ppt" "$BASE/slideshow/$f.ppt"
done
for f in SampleSS Simple 1904DateWindowing DateFormats rk text TwoSheetsOneHidden password xor-encryption-abc testEXCEL_95 \
         DBCSSheetName chinese-provinces empty duprich1 ContinueRecordProblem StringContinueRecords unicodeNameRecord SimpleMultiCell \
         angelo.edu_content_files_19555-nsse-2011-multiyear-benchmark \
         moodle.iamm.fr_pluginfile.php_2971_mod_resource_content_4_evaluation_module_decouverte_qesamed; do
    curl -sf -m 60 -o "$f.xls" "$BASE/spreadsheet/$f.xls"
done
for f in SampleSS sample DateFormatTests 51585 WithVariousData Formatting shared_formulas InlineStrings headerFooterTest; do
    curl -sf -m 60 -o "$f.xlsx" "$BASE/spreadsheet/$f.xlsx" || echo "missing $f.xlsx"
done
for f in sample SampleShow testPPT with_japanese table_test layouts shapes 45545_Comment; do
    curl -sf -m 60 -o "$f.pptx" "$BASE/slideshow/$f.pptx" || echo "missing $f.pptx"
done
ls -la
