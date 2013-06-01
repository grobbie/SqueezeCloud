set -x
cd ..
zip -r SqueezeCloud SqueezeCloud -x \*.zip \*.sh \*.git\* \*README\* \*webauth\*
mv SqueezeCloud.zip SqueezeCloud
cd SqueezeCloud

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')
SHA=$(shasum SqueezeCloud.zip | awk '{print $1;}')

cat <<EOF > public.xml
<extensions>
	<details>
		<title lang="EN">SqueezeCloud Plugin</title>
	</details>
	<plugins>
		<plugin name="SqueezeCloud" version="$VERSION" minTarget="7.5" maxTarget="*">
			<title lang="EN">SqueezeCloud</title>
			<desc lang="EN">Browse, search and play urls from soundcloud</desc>
			<url>https://github.com/grobbie/SqueezeCloud/SqueezeCloud.zip</url>
			<link>https://github.com/grobbie/SqueezeCloud</link>
			<sha>$SHA</sha>
			<creator>Robert Gibbon, David Blackman</creator>
			<email>robSPAMMENOTgibbon@me.com</email>
		</plugin>
	</plugins>
</extensions>
EOF

