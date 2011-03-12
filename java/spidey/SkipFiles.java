/*
   A Java class to specify a URL-exclusion list.

   Compile this file with:

   $ javac -classpath \
     /usr/lib/perl5/site_perl/5.8.5/WWW/HtmlUnit/jar/htmlunit-2.8.jar \
      SkipFiles.java

   and archive it with:

   $ cd ..
   $ jar cvf ../lib/WWW/HtmlUnit/jar/spidey-skipfiles-0.01.jar \
     spidey/SkipFiles.class spidey/'SkipFiles$1.class'

   It is important to include the directory spidey (same name as the package)
   into archived file paths.
*/

package spidey;

import java.io.IOException;
import java.util.regex.Pattern;
import com.gargoylesoftware.htmlunit.WebClient;
import com.gargoylesoftware.htmlunit.WebRequest;
import com.gargoylesoftware.htmlunit.WebResponse;
import com.gargoylesoftware.htmlunit.util.FalsifyingWebConnection;

public class SkipFiles {
    /* re is a regex of URLs to skip, e.g.:
       "\.js$" to skip all JavaScript files
       "(?:one|two)\.js$" to only skip one.js and two.js
    */
    public static FalsifyingWebConnection list(WebClient b, final String re) {
        return new FalsifyingWebConnection(b) {
            public WebResponse getResponse(WebRequest settings) throws IOException {
                WebResponse wr;
                Pattern p = Pattern.compile(re);
                // Does a subsequence of the URL match the exclusion-list regex?
                if (p.matcher(settings.getUrl().toExternalForm()).find()) {
                    // Return a fake response with an empty body and content/type.
                    wr = createWebResponse(settings, "", "");
                } else {
                    // Return the actual response.
                    wr = super.getResponse(settings);
                }
                return wr;
            }
        };
    }
}
