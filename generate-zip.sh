set -x
cd ..
zip -r SoundCloud SoundCloud -x \*.zip \*.sh \*.git\* \*README\*
mv SoundCloud.zip SoundCloud
cd SoundCloud

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')
SHA=$(shasum SoundCloud.zip | awk '{print $1;}')

cat <<EOF > public.xml
<extensions>
<details>
<title lang="EN">Whizziwig's Plugins</title>
</details>
<plugins>
<plugin name="SoundCloud" version="$VERSION" minTarget="7.5" maxTarget="*">
<title lang="EN">SoundCloud</title>
<desc lang="EN">Browse, search and play urls from soundcloud</desc>
<url>http://whizziwig.com/static/squeezecloud/SoundCloud.zip</url>
<link>https://github.com/blackmad/squeezecloud</link>
<sha>$SHA</sha>
<creator>David Blackman</creator>
<email>david+squeezecloud@whizziwig.com</email>
</plugin>
</plugins>
</extensions>
EOF

