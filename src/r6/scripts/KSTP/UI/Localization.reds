// Kiroshi Smart Targeting Protocol: item display strings.
//
// Registers the on-screen localization entries for the LocKey tokens named in
// src/r6/tweaks/KSTP/cyberware.yaml. The keys are duplicated across the two files; renaming one
// without the other renders a blank name and reports no error. See ADR 0008.
//
// Item record names resolve through GetLocalizedItemNameByCName (orphans.script:20082), which
// hashes the key and returns an empty string on a miss. Package UIData strings resolve through
// GetLocalizedText (orphans.script:19622), which returns its input, and so stay plain scalars.
//
// Requires Codeware.Localization, which writes each entry with primaryKey zero and secondaryKey
// set to the key string (Codeware.Localization.reds:366-370). Without it this file compiles out
// and item names render blank; no gameplay path reads these strings.

module KSTP.UI

@if(ModuleExists("Codeware.Localization"))
import Codeware.Localization.*

// Serves every locale the English package rather than an empty card.
@if(ModuleExists("Codeware.Localization"))
public class KSTPLocalization extends ModLocalizationProvider {

  public func GetPackage(language: CName) -> ref<ModLocalizationPackage> {
    return new KSTPEnglishText();
  }

  public func GetFallback() -> CName {
    return n"en-us";
  }
}

// The shipped English strings, one entry per LocKey token the item record cites.
@if(ModuleExists("Codeware.Localization"))
public class KSTPEnglishText extends ModLocalizationPackage {

  // One name covers all eleven quality steps and the flavour text carries no numbers: the UI
  // draws the quality tier and the tier's stat modifiers separately, so either would print twice.
  protected func DefineTexts() {
    this.Text("kstp_coprocessor_name", "Kiroshi IFF Targeting Coprocessor");

    this.Text("kstp_coprocessor_flavor",
      "Cross-references smart-link targeting data against an operator-set engagement "
      + "profile before authorizing a lock.");
  }
}
