"""
NEW GMWF DOCUMENT — copy this file, rename it, edit META and pages(), run it.

    python3 my_new_doc.py

The build prints  overflow: []  when every page fits.
Any page listed in 'overflow' has too much content: move some of it to a new page.
Requires: pip install playwright  and Google Chrome at /usr/bin/google-chrome.
"""
import sys; sys.path.insert(0, "kit")      # folder that contains kit.py and style.css
from kit import *

META = dict(
    ref="GMWF-SOP-XXX-01",                       # TYPE-AREA-NN   (add -UR for the Urdu edition)
    version_line="Version 1.0 · Month YYYY",
    tag="Short Type Label",                      # shown as the gold tag in the header
    dept="Department or programme name",
    short="Short title for the footer",
    title="Full document title",
)

def pages():
    p1 = (
        hero("Kicker label", "Page Title",
             "One sentence in English: what the person will do.",
             "اسی بات کا ایک جملہ اردو میں۔")
        + h2("Section name", "سیکشن کا نام")
        + steps(
            step(1, f'Open the {lbl("Screen Name")} tab.', "اسکرین کا نام کھولیں۔"),
            step(2, f'Press {btn("Save")}.', "محفوظ کریں۔"),
        )
        + callout("stop", "STOP — something looks wrong?", "Do not continue. Ask the Doctor or Branch Manager.",
                  "رک جائیں", "آگے نہ بڑھیں۔ ڈاکٹر یا برانچ مینیجر سے پوچھیں۔")
    )
    return [p1]

if __name__ == "__main__":
    # rtl=True builds a fully right-to-left Urdu edition (use u(), ustep(), ucard() blocks)
    print("overflow:", build_pdf(META, pages(), "out/MY_NEW_DOC.pdf", html_dir="build"))
