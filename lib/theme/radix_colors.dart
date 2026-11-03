// Radix Colors 3.0.0 (https://www.radix-ui.com/colors, @radix-ui/colors, MIT).
// Every colour in the interface comes from here. What each step is for:
//   1-2 backgrounds, 3 element background, 4 hovered, 5 pressed or selected,
//   6 subtle border, 7 border, 8 hovered border, 9 solid, 10 hovered solid,
//   11 low-contrast text, 12 high-contrast text.
// Copied from the package as it is: do not edit the values.
import 'dart:ui';

abstract final class Radix {
  static const white = Color(0xFFFFFFFF);
  static const black = Color(0xFF000000);

  /// See-through white, so a gradient to it does not pass through grey.
  static const whiteA0 = Color(0x00FFFFFF);

  static const whiteA1 = Color(0x0DFFFFFF);
  static const whiteA2 = Color(0x1AFFFFFF);
  static const whiteA3 = Color(0x26FFFFFF);
  static const whiteA4 = Color(0x33FFFFFF);
  static const whiteA5 = Color(0x4DFFFFFF);
  static const whiteA6 = Color(0x66FFFFFF);
  static const whiteA7 = Color(0x80FFFFFF);
  static const whiteA8 = Color(0x99FFFFFF);
  static const whiteA9 = Color(0xB3FFFFFF);
  static const whiteA10 = Color(0xCCFFFFFF);
  static const whiteA11 = Color(0xE6FFFFFF);
  static const whiteA12 = Color(0xF2FFFFFF);

  static const blackA1 = Color(0x0D000000);
  static const blackA2 = Color(0x1A000000);
  static const blackA3 = Color(0x26000000);
  static const blackA4 = Color(0x33000000);
  static const blackA5 = Color(0x4D000000);
  static const blackA6 = Color(0x66000000);
  static const blackA7 = Color(0x80000000);
  static const blackA8 = Color(0x99000000);
  static const blackA9 = Color(0xB3000000);
  static const blackA10 = Color(0xCC000000);
  static const blackA11 = Color(0xE6000000);
  static const blackA12 = Color(0xF2000000);

  static const slate1 = Color(0xFFFCFCFD);
  static const slate2 = Color(0xFFF9F9FB);
  static const slate3 = Color(0xFFF0F0F3);
  static const slate4 = Color(0xFFE8E8EC);
  static const slate5 = Color(0xFFE0E1E6);
  static const slate6 = Color(0xFFD9D9E0);
  static const slate7 = Color(0xFFCDCED6);
  static const slate8 = Color(0xFFB9BBC6);
  static const slate9 = Color(0xFF8B8D98);
  static const slate10 = Color(0xFF80838D);
  static const slate11 = Color(0xFF60646C);
  static const slate12 = Color(0xFF1C2024);

  static const slateDark1 = Color(0xFF111113);
  static const slateDark2 = Color(0xFF18191B);
  static const slateDark3 = Color(0xFF212225);
  static const slateDark4 = Color(0xFF272A2D);
  static const slateDark5 = Color(0xFF2E3135);
  static const slateDark6 = Color(0xFF363A3F);
  static const slateDark7 = Color(0xFF43484E);
  static const slateDark8 = Color(0xFF5A6169);
  static const slateDark9 = Color(0xFF696E77);
  static const slateDark10 = Color(0xFF777B84);
  static const slateDark11 = Color(0xFFB0B4BA);
  static const slateDark12 = Color(0xFFEDEEF0);

  static const blue1 = Color(0xFFFBFDFF);
  static const blue2 = Color(0xFFF4FAFF);
  static const blue3 = Color(0xFFE6F4FE);
  static const blue4 = Color(0xFFD5EFFF);
  static const blue5 = Color(0xFFC2E5FF);
  static const blue6 = Color(0xFFACD8FC);
  static const blue7 = Color(0xFF8EC8F6);
  static const blue8 = Color(0xFF5EB1EF);
  static const blue9 = Color(0xFF0090FF);
  static const blue10 = Color(0xFF0588F0);
  static const blue11 = Color(0xFF0D74CE);
  static const blue12 = Color(0xFF113264);

  static const blueDark1 = Color(0xFF0D1520);
  static const blueDark2 = Color(0xFF111927);
  static const blueDark3 = Color(0xFF0D2847);
  static const blueDark4 = Color(0xFF003362);
  static const blueDark5 = Color(0xFF004074);
  static const blueDark6 = Color(0xFF104D87);
  static const blueDark7 = Color(0xFF205D9E);
  static const blueDark8 = Color(0xFF2870BD);
  static const blueDark9 = Color(0xFF0090FF);
  static const blueDark10 = Color(0xFF3B9EFF);
  static const blueDark11 = Color(0xFF70B8FF);
  static const blueDark12 = Color(0xFFC2E6FF);

  static const indigo1 = Color(0xFFFDFDFE);
  static const indigo2 = Color(0xFFF7F9FF);
  static const indigo3 = Color(0xFFEDF2FE);
  static const indigo4 = Color(0xFFE1E9FF);
  static const indigo5 = Color(0xFFD2DEFF);
  static const indigo6 = Color(0xFFC1D0FF);
  static const indigo7 = Color(0xFFABBDF9);
  static const indigo8 = Color(0xFF8DA4EF);
  static const indigo9 = Color(0xFF3E63DD);
  static const indigo10 = Color(0xFF3358D4);
  static const indigo11 = Color(0xFF3A5BC7);
  static const indigo12 = Color(0xFF1F2D5C);

  static const indigoDark1 = Color(0xFF11131F);
  static const indigoDark2 = Color(0xFF141726);
  static const indigoDark3 = Color(0xFF182449);
  static const indigoDark4 = Color(0xFF1D2E62);
  static const indigoDark5 = Color(0xFF253974);
  static const indigoDark6 = Color(0xFF304384);
  static const indigoDark7 = Color(0xFF3A4F97);
  static const indigoDark8 = Color(0xFF435DB1);
  static const indigoDark9 = Color(0xFF3E63DD);
  static const indigoDark10 = Color(0xFF5472E4);
  static const indigoDark11 = Color(0xFF9EB1FF);
  static const indigoDark12 = Color(0xFFD6E1FF);

  static const iris1 = Color(0xFFFDFDFF);
  static const iris2 = Color(0xFFF8F8FF);
  static const iris3 = Color(0xFFF0F1FE);
  static const iris4 = Color(0xFFE6E7FF);
  static const iris5 = Color(0xFFDADCFF);
  static const iris6 = Color(0xFFCBCDFF);
  static const iris7 = Color(0xFFB8BAF8);
  static const iris8 = Color(0xFF9B9EF0);
  static const iris9 = Color(0xFF5B5BD6);
  static const iris10 = Color(0xFF5151CD);
  static const iris11 = Color(0xFF5753C6);
  static const iris12 = Color(0xFF272962);

  static const irisDark1 = Color(0xFF13131E);
  static const irisDark2 = Color(0xFF171625);
  static const irisDark3 = Color(0xFF202248);
  static const irisDark4 = Color(0xFF262A65);
  static const irisDark5 = Color(0xFF303374);
  static const irisDark6 = Color(0xFF3D3E82);
  static const irisDark7 = Color(0xFF4A4A95);
  static const irisDark8 = Color(0xFF5958B1);
  static const irisDark9 = Color(0xFF5B5BD6);
  static const irisDark10 = Color(0xFF6E6ADE);
  static const irisDark11 = Color(0xFFB1A9FF);
  static const irisDark12 = Color(0xFFE0DFFE);

  static const violet1 = Color(0xFFFDFCFE);
  static const violet2 = Color(0xFFFAF8FF);
  static const violet3 = Color(0xFFF4F0FE);
  static const violet4 = Color(0xFFEBE4FF);
  static const violet5 = Color(0xFFE1D9FF);
  static const violet6 = Color(0xFFD4CAFE);
  static const violet7 = Color(0xFFC2B5F5);
  static const violet8 = Color(0xFFAA99EC);
  static const violet9 = Color(0xFF6E56CF);
  static const violet10 = Color(0xFF654DC4);
  static const violet11 = Color(0xFF6550B9);
  static const violet12 = Color(0xFF2F265F);

  static const violetDark1 = Color(0xFF14121F);
  static const violetDark2 = Color(0xFF1B1525);
  static const violetDark3 = Color(0xFF291F43);
  static const violetDark4 = Color(0xFF33255B);
  static const violetDark5 = Color(0xFF3C2E69);
  static const violetDark6 = Color(0xFF473876);
  static const violetDark7 = Color(0xFF56468B);
  static const violetDark8 = Color(0xFF6958AD);
  static const violetDark9 = Color(0xFF6E56CF);
  static const violetDark10 = Color(0xFF7D66D9);
  static const violetDark11 = Color(0xFFBAA7FF);
  static const violetDark12 = Color(0xFFE2DDFE);

  static const purple1 = Color(0xFFFEFCFE);
  static const purple2 = Color(0xFFFBF7FE);
  static const purple3 = Color(0xFFF7EDFE);
  static const purple4 = Color(0xFFF2E2FC);
  static const purple5 = Color(0xFFEAD5F9);
  static const purple6 = Color(0xFFE0C4F4);
  static const purple7 = Color(0xFFD1AFEC);
  static const purple8 = Color(0xFFBE93E4);
  static const purple9 = Color(0xFF8E4EC6);
  static const purple10 = Color(0xFF8347B9);
  static const purple11 = Color(0xFF8145B5);
  static const purple12 = Color(0xFF402060);

  static const purpleDark1 = Color(0xFF18111B);
  static const purpleDark2 = Color(0xFF1E1523);
  static const purpleDark3 = Color(0xFF301C3B);
  static const purpleDark4 = Color(0xFF3D224E);
  static const purpleDark5 = Color(0xFF48295C);
  static const purpleDark6 = Color(0xFF54346B);
  static const purpleDark7 = Color(0xFF664282);
  static const purpleDark8 = Color(0xFF8457AA);
  static const purpleDark9 = Color(0xFF8E4EC6);
  static const purpleDark10 = Color(0xFF9A5CD0);
  static const purpleDark11 = Color(0xFFD19DFF);
  static const purpleDark12 = Color(0xFFECD9FA);

  static const pink1 = Color(0xFFFFFCFE);
  static const pink2 = Color(0xFFFEF7FB);
  static const pink3 = Color(0xFFFEE9F5);
  static const pink4 = Color(0xFFFBDCEF);
  static const pink5 = Color(0xFFF6CEE7);
  static const pink6 = Color(0xFFEFBFDD);
  static const pink7 = Color(0xFFE7ACD0);
  static const pink8 = Color(0xFFDD93C2);
  static const pink9 = Color(0xFFD6409F);
  static const pink10 = Color(0xFFCF3897);
  static const pink11 = Color(0xFFC2298A);
  static const pink12 = Color(0xFF651249);

  static const pinkDark1 = Color(0xFF191117);
  static const pinkDark2 = Color(0xFF21121D);
  static const pinkDark3 = Color(0xFF37172F);
  static const pinkDark4 = Color(0xFF4B143D);
  static const pinkDark5 = Color(0xFF591C47);
  static const pinkDark6 = Color(0xFF692955);
  static const pinkDark7 = Color(0xFF833869);
  static const pinkDark8 = Color(0xFFA84885);
  static const pinkDark9 = Color(0xFFD6409F);
  static const pinkDark10 = Color(0xFFDE51A8);
  static const pinkDark11 = Color(0xFFFF8DCC);
  static const pinkDark12 = Color(0xFFFDD1EA);

  static const crimson1 = Color(0xFFFFFCFD);
  static const crimson2 = Color(0xFFFEF7F9);
  static const crimson3 = Color(0xFFFFE9F0);
  static const crimson4 = Color(0xFFFEDCE7);
  static const crimson5 = Color(0xFFFACEDD);
  static const crimson6 = Color(0xFFF3BED1);
  static const crimson7 = Color(0xFFEAACC3);
  static const crimson8 = Color(0xFFE093B2);
  static const crimson9 = Color(0xFFE93D82);
  static const crimson10 = Color(0xFFDF3478);
  static const crimson11 = Color(0xFFCB1D63);
  static const crimson12 = Color(0xFF621639);

  static const crimsonDark1 = Color(0xFF191114);
  static const crimsonDark2 = Color(0xFF201318);
  static const crimsonDark3 = Color(0xFF381525);
  static const crimsonDark4 = Color(0xFF4D122F);
  static const crimsonDark5 = Color(0xFF5C1839);
  static const crimsonDark6 = Color(0xFF6D2545);
  static const crimsonDark7 = Color(0xFF873356);
  static const crimsonDark8 = Color(0xFFB0436E);
  static const crimsonDark9 = Color(0xFFE93D82);
  static const crimsonDark10 = Color(0xFFEE518A);
  static const crimsonDark11 = Color(0xFFFF92AD);
  static const crimsonDark12 = Color(0xFFFDD3E8);

  static const red1 = Color(0xFFFFFCFC);
  static const red2 = Color(0xFFFFF7F7);
  static const red3 = Color(0xFFFEEBEC);
  static const red4 = Color(0xFFFFDBDC);
  static const red5 = Color(0xFFFFCDCE);
  static const red6 = Color(0xFFFDBDBE);
  static const red7 = Color(0xFFF4A9AA);
  static const red8 = Color(0xFFEB8E90);
  static const red9 = Color(0xFFE5484D);
  static const red10 = Color(0xFFDC3E42);
  static const red11 = Color(0xFFCE2C31);
  static const red12 = Color(0xFF641723);

  static const redDark1 = Color(0xFF191111);
  static const redDark2 = Color(0xFF201314);
  static const redDark3 = Color(0xFF3B1219);
  static const redDark4 = Color(0xFF500F1C);
  static const redDark5 = Color(0xFF611623);
  static const redDark6 = Color(0xFF72232D);
  static const redDark7 = Color(0xFF8C333A);
  static const redDark8 = Color(0xFFB54548);
  static const redDark9 = Color(0xFFE5484D);
  static const redDark10 = Color(0xFFEC5D5E);
  static const redDark11 = Color(0xFFFF9592);
  static const redDark12 = Color(0xFFFFD1D9);

  static const orange1 = Color(0xFFFEFCFB);
  static const orange2 = Color(0xFFFFF7ED);
  static const orange3 = Color(0xFFFFEFD6);
  static const orange4 = Color(0xFFFFDFB5);
  static const orange5 = Color(0xFFFFD19A);
  static const orange6 = Color(0xFFFFC182);
  static const orange7 = Color(0xFFF5AE73);
  static const orange8 = Color(0xFFEC9455);
  static const orange9 = Color(0xFFF76B15);
  static const orange10 = Color(0xFFEF5F00);
  static const orange11 = Color(0xFFCC4E00);
  static const orange12 = Color(0xFF582D1D);

  static const orangeDark1 = Color(0xFF17120E);
  static const orangeDark2 = Color(0xFF1E160F);
  static const orangeDark3 = Color(0xFF331E0B);
  static const orangeDark4 = Color(0xFF462100);
  static const orangeDark5 = Color(0xFF562800);
  static const orangeDark6 = Color(0xFF66350C);
  static const orangeDark7 = Color(0xFF7E451D);
  static const orangeDark8 = Color(0xFFA35829);
  static const orangeDark9 = Color(0xFFF76B15);
  static const orangeDark10 = Color(0xFFFF801F);
  static const orangeDark11 = Color(0xFFFFA057);
  static const orangeDark12 = Color(0xFFFFE0C2);

  static const amber1 = Color(0xFFFEFDFB);
  static const amber2 = Color(0xFFFEFBE9);
  static const amber3 = Color(0xFFFFF7C2);
  static const amber4 = Color(0xFFFFEE9C);
  static const amber5 = Color(0xFFFBE577);
  static const amber6 = Color(0xFFF3D673);
  static const amber7 = Color(0xFFE9C162);
  static const amber8 = Color(0xFFE2A336);
  static const amber9 = Color(0xFFFFC53D);
  static const amber10 = Color(0xFFFFBA18);
  static const amber11 = Color(0xFFAB6400);
  static const amber12 = Color(0xFF4F3422);

  static const amberDark1 = Color(0xFF16120C);
  static const amberDark2 = Color(0xFF1D180F);
  static const amberDark3 = Color(0xFF302008);
  static const amberDark4 = Color(0xFF3F2700);
  static const amberDark5 = Color(0xFF4D3000);
  static const amberDark6 = Color(0xFF5C3D05);
  static const amberDark7 = Color(0xFF714F19);
  static const amberDark8 = Color(0xFF8F6424);
  static const amberDark9 = Color(0xFFFFC53D);
  static const amberDark10 = Color(0xFFFFD60A);
  static const amberDark11 = Color(0xFFFFCA16);
  static const amberDark12 = Color(0xFFFFE7B3);

  static const brown1 = Color(0xFFFEFDFC);
  static const brown2 = Color(0xFFFCF9F6);
  static const brown3 = Color(0xFFF6EEE7);
  static const brown4 = Color(0xFFF0E4D9);
  static const brown5 = Color(0xFFEBDACA);
  static const brown6 = Color(0xFFE4CDB7);
  static const brown7 = Color(0xFFDCBC9F);
  static const brown8 = Color(0xFFCEA37E);
  static const brown9 = Color(0xFFAD7F58);
  static const brown10 = Color(0xFFA07553);
  static const brown11 = Color(0xFF815E46);
  static const brown12 = Color(0xFF3E332E);

  static const brownDark1 = Color(0xFF12110F);
  static const brownDark2 = Color(0xFF1C1816);
  static const brownDark3 = Color(0xFF28211D);
  static const brownDark4 = Color(0xFF322922);
  static const brownDark5 = Color(0xFF3E3128);
  static const brownDark6 = Color(0xFF4D3C2F);
  static const brownDark7 = Color(0xFF614A39);
  static const brownDark8 = Color(0xFF7C5F46);
  static const brownDark9 = Color(0xFFAD7F58);
  static const brownDark10 = Color(0xFFB88C67);
  static const brownDark11 = Color(0xFFDBB594);
  static const brownDark12 = Color(0xFFF2E1CA);

  static const green1 = Color(0xFFFBFEFC);
  static const green2 = Color(0xFFF4FBF6);
  static const green3 = Color(0xFFE6F6EB);
  static const green4 = Color(0xFFD6F1DF);
  static const green5 = Color(0xFFC4E8D1);
  static const green6 = Color(0xFFADDDC0);
  static const green7 = Color(0xFF8ECEAA);
  static const green8 = Color(0xFF5BB98B);
  static const green9 = Color(0xFF30A46C);
  static const green10 = Color(0xFF2B9A66);
  static const green11 = Color(0xFF218358);
  static const green12 = Color(0xFF193B2D);

  static const greenDark1 = Color(0xFF0E1512);
  static const greenDark2 = Color(0xFF121B17);
  static const greenDark3 = Color(0xFF132D21);
  static const greenDark4 = Color(0xFF113B29);
  static const greenDark5 = Color(0xFF174933);
  static const greenDark6 = Color(0xFF20573E);
  static const greenDark7 = Color(0xFF28684A);
  static const greenDark8 = Color(0xFF2F7C57);
  static const greenDark9 = Color(0xFF30A46C);
  static const greenDark10 = Color(0xFF33B074);
  static const greenDark11 = Color(0xFF3DD68C);
  static const greenDark12 = Color(0xFFB1F1CB);

  static const teal1 = Color(0xFFFAFEFD);
  static const teal2 = Color(0xFFF3FBF9);
  static const teal3 = Color(0xFFE0F8F3);
  static const teal4 = Color(0xFFCCF3EA);
  static const teal5 = Color(0xFFB8EAE0);
  static const teal6 = Color(0xFFA1DED2);
  static const teal7 = Color(0xFF83CDC1);
  static const teal8 = Color(0xFF53B9AB);
  static const teal9 = Color(0xFF12A594);
  static const teal10 = Color(0xFF0D9B8A);
  static const teal11 = Color(0xFF008573);
  static const teal12 = Color(0xFF0D3D38);

  static const tealDark1 = Color(0xFF0D1514);
  static const tealDark2 = Color(0xFF111C1B);
  static const tealDark3 = Color(0xFF0D2D2A);
  static const tealDark4 = Color(0xFF023B37);
  static const tealDark5 = Color(0xFF084843);
  static const tealDark6 = Color(0xFF145750);
  static const tealDark7 = Color(0xFF1C6961);
  static const tealDark8 = Color(0xFF207E73);
  static const tealDark9 = Color(0xFF12A594);
  static const tealDark10 = Color(0xFF0EB39E);
  static const tealDark11 = Color(0xFF0BD8B6);
  static const tealDark12 = Color(0xFFADF0DD);

  static const cyan1 = Color(0xFFFAFDFE);
  static const cyan2 = Color(0xFFF2FAFB);
  static const cyan3 = Color(0xFFDEF7F9);
  static const cyan4 = Color(0xFFCAF1F6);
  static const cyan5 = Color(0xFFB5E9F0);
  static const cyan6 = Color(0xFF9DDDE7);
  static const cyan7 = Color(0xFF7DCEDC);
  static const cyan8 = Color(0xFF3DB9CF);
  static const cyan9 = Color(0xFF00A2C7);
  static const cyan10 = Color(0xFF0797B9);
  static const cyan11 = Color(0xFF107D98);
  static const cyan12 = Color(0xFF0D3C48);

  static const cyanDark1 = Color(0xFF0B161A);
  static const cyanDark2 = Color(0xFF101B20);
  static const cyanDark3 = Color(0xFF082C36);
  static const cyanDark4 = Color(0xFF003848);
  static const cyanDark5 = Color(0xFF004558);
  static const cyanDark6 = Color(0xFF045468);
  static const cyanDark7 = Color(0xFF12677E);
  static const cyanDark8 = Color(0xFF11809C);
  static const cyanDark9 = Color(0xFF00A2C7);
  static const cyanDark10 = Color(0xFF23AFD0);
  static const cyanDark11 = Color(0xFF4CCCE6);
  static const cyanDark12 = Color(0xFFB6ECF7);

  static const slateA1 = Color(0x03000055);
  static const slateA2 = Color(0x06000055);
  static const slateA3 = Color(0x0F000033);
  static const slateA4 = Color(0x1700002D);
  static const slateA5 = Color(0x1F000932);
  static const slateA6 = Color(0x2600002F);
  static const slateA7 = Color(0x3200062E);
  static const slateA8 = Color(0x46000830);
  static const slateA9 = Color(0x7400051D);
  static const slateA10 = Color(0x7F00071B);
  static const slateA11 = Color(0x9F000714);
  static const slateA12 = Color(0xE3000509);

  static const slateDarkA1 = Color(0x00000000);
  static const slateDarkA2 = Color(0x09D8F4F6);
  static const slateDarkA3 = Color(0x14DDEAF8);
  static const slateDarkA4 = Color(0x1DD3EDF8);
  static const slateDarkA5 = Color(0x25D9EDFE);
  static const slateDarkA6 = Color(0x30D6EBFD);
  static const slateDarkA7 = Color(0x40D9EDFF);
  static const slateDarkA8 = Color(0x5DD9EDFF);
  static const slateDarkA9 = Color(0x6DDFEBFD);
  static const slateDarkA10 = Color(0x7BE5EDFD);
  static const slateDarkA11 = Color(0xB5F1F7FE);
  static const slateDarkA12 = Color(0xEFFCFDFF);

  static const blueA1 = Color(0x040080FF);
  static const blueA2 = Color(0x0B008CFF);
  static const blueA3 = Color(0x19008FF5);
  static const blueA4 = Color(0x2A009EFF);
  static const blueA5 = Color(0x3D0093FF);
  static const blueA6 = Color(0x530088F6);
  static const blueA7 = Color(0x710083EB);
  static const blueA8 = Color(0xA10084E6);
  static const blueA10 = Color(0xFA0086F0);
  static const blueA11 = Color(0xF2006DCB);
  static const blueA12 = Color(0xEE002359);

  static const blueDarkA1 = Color(0x11004DF2);
  static const blueDarkA2 = Color(0x181166FB);
  static const blueDarkA3 = Color(0x3A0077FF);
  static const blueDarkA4 = Color(0x570075FF);
  static const blueDarkA5 = Color(0x6B0081FD);
  static const blueDarkA6 = Color(0x7F0F89FD);
  static const blueDarkA7 = Color(0x982A91FE);
  static const blueDarkA8 = Color(0xB93094FE);
}
