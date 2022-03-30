## 阿里云镜像构建使用dpkg安装报错处理方法



安装google-chorme，使用了deb包安装的办法。在进行deb安装会检验是否已经安装了必须的依赖，否则会出现一些提示信息。此时可能会存在"error"字眼的提示信息，阿里云会认为这是出现了构建错误导致构建停止。

要避免上述情况出现，可检查缺少的依赖，在进行deb安装前先完成依赖的安装从而避开出现“error”的提示即可



```dockerfile
RUN apt-get update && apt-get -y install zip wget unzip xdg-utils \
  && apt-get -y install fonts-liberation fonts-liberation libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 \
  libdrm2 libgbm1 libgtk-3-0 libnspr4 libasound2 \
  libnss3 libpango-1.0-0 libxcomposite1 libxdamage1 libxkbcommon0\
  && wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
  && dpkg -i --force-depends google-chrome-stable_current_amd64.deb \
  && apt-get -y -f install \
  && dpkg -i --force-depends google-chrome-stable_current_amd64.deb \
  && rm google-chrome-stable_current_amd64.deb \
  && wget https://chromedriver.storage.googleapis.com/${CHROME_DRIVER_VERSION}/chromedriver_linux64.zip \
  && unzip chromedriver_linux64.zip \
  && mv chromedriver /usr/local/bin/ \
  && rm chromedriver_linux64.zip
```

这里的deb包就缺少common0的依赖，导致出现了error提示，因此在进行 deb安装前就先把libxkbcommon0安装好，后面的安装才能顺利进行
